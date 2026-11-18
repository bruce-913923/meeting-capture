# Meeting Capture

macOS 選單列小程式：線上會議開始時按「開始」，同時錄下電腦播出的聲音、在換頁時截下簡報、辨識畫面上的字幕；按「結束」後在本機轉成文字，再交給 Claude 或 Codex 依你選的整理方式寫成文章（存本機，或用你自己的 skill 寫進 Notion 等地方）。

設計理由見 [docs/design.md](docs/design.md)。

## 建置與安裝

```bash
./scripts/make-app.sh
open build/MeetingCapture.app
```

需要 macOS 14 以上（「只錄麥克風」與「錄現場麥克風」需要 macOS 15）。

**本機預設值（選用）**：把 `config.example.json` 複製成 `config.local.json`，填入語音模型資料夾、Python 路徑和起始的常用詞彙。`make-app.sh` 會把它打包進 app。只有在設定裡的欄位還是空白時才會帶入；路徑不存在就略過，`~` 會展開成家目錄。`config.local.json` 已經加進 `.gitignore`，不會進 git。不放這個檔也可以，直接在 app 的設定裡選路徑就好。

第一次按「開始擷取」時，系統會要求權限：

- **螢幕與系統錄音**：系統設定 › 隱私權與安全性 › 螢幕與系統錄音，勾選 Meeting Capture，然後重新打開 app。
- **麥克風**：第一次打開「錄現場麥克風」或使用「只錄麥克風」時才會要。
- **語音辨識**：只有轉文字引擎選「macOS 內建」才會要。

**簽章與螢幕錄音權限**：螢幕錄音權限綁的是 app 的簽章條件。`make-app.sh` 若在鑰匙圈找到「Meeting Capture Local Signing」憑證就用它簽，簽章條件固定（識別碼＋這張憑證），改版重建不用重新授權；找不到就退回臨時簽章，每次重建都要重新授權。在別台電腦建立這張憑證：

```bash
# 產生只給本 app 用的自簽簽章憑證（10 年），匯入登入鑰匙圈
cat > /tmp/mc.cnf <<'CNF'
[req]
distinguished_name=dn
prompt=no
x509_extensions=ext
[dn]
CN=Meeting Capture Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/mc.key -out /tmp/mc.crt -days 3650 -config /tmp/mc.cnf
openssl pkcs12 -export -legacy -inkey /tmp/mc.key -in /tmp/mc.crt -out /tmp/mc.p12 -passout pass:tmp -name "Meeting Capture Local Signing"
security import /tmp/mc.p12 -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign
rm /tmp/mc.*
```

`security find-identity -p codesigning` 會顯示它「未受信任」，這是自簽憑證的正常狀態，不影響簽章。

換簽章方式（或第一次用固定憑證）時，系統設定裡舊的那筆要先按「−」刪掉，再按「＋」加入新版。

## 使用前一定要知道

- **線上會議（Teams、Meet、Zoom）錄的是電腦播出的聲音，喇叭不能靜音。** 音量開到最小也錄得到，你在會議裡保持靜音也沒關係。按開始時如果偵測到靜音，app 會提供「解除靜音並調到最小音量」的按鈕。
- **有人在現場講話**（會議室有人、你自己也會發言、會後留下來討論）：這些聲音不會從你電腦播出來，開始擷取後打開「錄現場麥克風」。錄音中隨時可以開關，麥克風錄音存在同一個會議資料夾（`mic/`）。
- **沒開會議軟體的實體會議**：用「只錄麥克風」，不截圖。
- 錄音前請讓與會者知道會議有錄音。

## 選單

| 項目 | 說明 |
|---|---|
| 開始擷取 › | 選要截的視窗，點了就開始：「會議軟體」列出認得的會議視窗（Teams、Zoom、Webex，或標題含會議關鍵字的瀏覽器分頁；有 Teams「彈出視窗」時選它最準）；「瀏覽器」列出其他瀏覽器視窗（網頁研討會等，截的是最前面那個分頁）；都沒有就從「其他視窗」挑 |
| 錄現場麥克風（錄音中） | 線上會議錄音中的開關。打開時選單最上面顯示「🎙 正在錄現場聲音」。現場有人講話、會後留下來討論時打開，不用結束擷取 |
| 匯入錄影或錄音檔… | 選一個錄影檔（Teams 錄影的 mp4 等）或錄音檔（m4a、mp3、wav 等；錄音檔沒有畫面，只轉文字）。同名資料夾已存在會自動加 -2、-3，不會覆蓋。錄影會抽出音軌切段放 `audio/`、每隔幾秒取一張畫面做換頁判斷與字幕辨識，接著轉文字並跳出整理視窗。時間標記用影片內時間（00:00:00 起算）。1 小時影片抽畫面約 5 分鐘，轉文字另計 |
| 結束擷取 | 停止錄音與截圖，排進背景轉文字，完成後跳出整理視窗。用 MLX／faster-whisper 且開著「錄音中就開始轉文字」（預設開）時，錄音中已經一段一段轉好，結束後只剩最後一段。轉文字時照樣可以馬上「開始擷取」下一場；選單會多一行「背景轉文字：…」。好幾場時一場一場排隊轉。錄下一場時上一場轉好，只發通知、不跳視窗，等這場結束才一起跳出（也可以從「整理會議」先打開） |
| 整理會議 | 列出最近 10 場（依開始時間，✓＝已有整理結果），點一下開整理視窗；更早的或別處的會議用「開啟其他會議資料夾…」 |
| 重新轉文字、打開會議資料夾 | 針對最後一次選的那場；換轉文字引擎後可重跑 |

## 整理視窗

1. **這場會議**：會議名稱、會議說明（背景、與會者、專有名詞；存成 `notes.md`，AI 以這段為準）。錄音過程中不用填，結束後跳出整理視窗再寫。
2. **要產出什麼**：會議摘要（條列結論與討論重點，小會議）、會議紀錄（決議、待辦、各議題討論，專案會議）、分享文章（配簡報圖，技術分享）、自訂；再加「這次的額外要求」，優先於任何預設格式。
3. **放到哪裡、用哪個 AI**：只存在本機，或選一個 skill（例如寫進 Notion）；Claude 或 Codex、模型。選 skill 時，放到哪裡照 skill，內容格式照第 2 步。
4. **執行時允許使用的連線**（Claude）：列出命令列 `claude mcp list` 的連線，勾了執行階段才能用。要寫 Notion 就要勾 Notion 的連線；選了會寫 Notion 的 skill 卻沒勾，畫面會先警告。
5. AI 先看會議內容，只問它判斷不了的事（例如放哪個資料庫），再按「確認並執行」。不論放到哪裡，會議資料夾都會留一份 `summary.md`／`minutes.md`／`article.md`／`output.md`。

規劃那一步 AI 只能讀檔；執行那一步才允許寫檔、跑指令、勾選的連線，以及設定裡「額外允許的工具」。

**Notion 連線注意**：同一個服務常有兩個連線（claude.ai 網頁端的「claude.ai Notion」和本機的「plugin:engineering:notion」），執行時 AI 可能挑任一個用。勾其中一個，app 會把同服務的連線一起放行（包括 `claude mcp list` 因網址重複而沒列出的 claude.ai 版）。本機那個沒授權時：在終端機輸入 `claude`，打 `/mcp` 完成登入。工具被擋下時，結果畫面會列出被擋的完整工具名稱。

## 常用詞彙（人名、專有名詞）

設定 › 常用詞彙，一行一個；直接打詞就好；知道常被聽錯成什麼的，寫成 `小名、曉明 > 曉銘`（錯的在左、對的在右；`>` 也可寫 `->`、`=>`、`→`）。會用在三個地方：

1. 轉文字時當提示詞給語音模型（模型吃得下的長度有限，依表上順序取到約 120 字，越前面越優先）（Breeze／MLX 每 30 秒一個視窗都補上，不只開頭；faster-whisper 用 hotwords）。
2. 轉完把箭頭左邊的錯字換成右邊（所有引擎都有）。錯字別寫成常見詞，否則會誤換。
3. 整理時交給 AI 當專有名詞依據。

**提示放哪些詞**：標題含「人名」或「固定」的那一區（例如 `# 人名`）每次都排最前面；其他詞依最近 5 場會議「被換掉的次數×3＋出現次數」自動挑，放到約 120 字為止。設定裡按「看下一場會給語音模型哪些詞」可以預覽。每場被換掉的次數記在會議資料夾的 `glossary-fixes.json`。

**自己累積**：AI 整理完，結果畫面會列出「AI 認為逐字稿聽錯的詞」（例如 `笑名 > 曉銘`），預設全勾，取消常見詞後按「加入常用詞彙」。人名會加進人名區，同一個正確詞已有那行就把錯字補上去。

只影響之後轉的文字，舊會議要按「重新轉文字」。注意：提示詞會把近音的名字拉向表上的寫法，表上沒有的同音名字可能被誤寫成表上的人。

## 轉文字引擎

設定 › 轉文字，選好後按「用一段中文測試音檔試跑」確認能用。

| 引擎 | 需要什麼 |
|---|---|
| MLX Whisper | Apple Silicon；模型資料夾（例如 Breeze-ASR-25 MLX）＋裝了 `mlx_whisper` 的 Python |
| faster-whisper | CTranslate2 模型資料夾＋裝了 `faster_whisper` 的 Python |
| 自訂指令 | 任何能吃音檔吐文字的工具，例如 `whisper-cli -m {model} -f {audio} -otxt -of {out}` |
| macOS 內建 | 不用裝任何東西，準確度較低 |

## 會議資料夾

預設在 `~/MeetingCapture/<日期>-<時間>-<標題>/`：

- `audio/`：電腦播出的聲音，每 10 分鐘一段 m4a；旁邊同名的 `.txt` 是這段的轉文字結果（錄音中每段完成就先轉，結束後不重轉；「重新轉文字」會清掉重轉）
- `mic/`：麥克風錄音（有打開「錄現場麥克風」或「只錄麥克風」才有）
- `frames/`：換頁時整個視窗的原圖
- `slides/`：自動切出的簡報區；`slides/index.json` 記錄哪些頁切不出來、只存了原圖
- `captions.txt`：畫面字幕辨識（附時間）
- `transcript.txt`、`transcript-mic.txt`：轉文字結果
- `live/`、`live-transcript.txt`：只在錄音中存在。每 2 分鐘一份、前後重疊 5 秒的草稿音檔與拼好的即時逐字稿（會議助手用），正式逐字稿轉好後自動刪除
- `notes.md`：你寫的會議說明；`request.md`：上次的整理要求
- `summary.md`／`minutes.md`／`article.md`／`output.md`：依產出類型留在本機的整理結果

## 開發用命令列

```bash
APP=build/MeetingCapture.app/Contents/MacOS/MeetingCapture
$APP --cli test-transcribe
$APP --cli skills
$APP --cli import <影片檔>    # 匯入錄影或錄音檔，印出建立的會議資料夾
$APP --cli mcp            # 列出命令列 claude 的連線與工具名稱前綴
$APP --cli plan <會議資料夾> [builtin|SKILL.md 路徑] [claude|codex]
$APP --cli execute <會議資料夾> <skill> <provider> '<答案 JSON>'
```

## 已知限制與待做

- 講者分離（同一支麥克風有多人輪流說話時分出 A、B、C）尚未實作，規劃做成可替換的模組。
- 命令列的 `claude` 要自己登入並授權 Notion 連線，桌面 app 的連線不共用。
