import Foundation

/// 內嵌的腳本與規則；執行時寫到 Application Support，避免 .app 打包資源的麻煩。
enum Resources {
    static var dir: URL {
        let d = Settings.fileURL.deletingLastPathComponent().appendingPathComponent("resources")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @discardableResult
    static func write(name: String, content: String) -> URL {
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static let transcribePy = #"""
import argparse, os, sys, datetime

ap = argparse.ArgumentParser()
ap.add_argument("--engine", required=True)
ap.add_argument("--model", required=True)
ap.add_argument("--language", default="zh")
ap.add_argument("--audio-dir")
ap.add_argument("--out")
# 逐檔模式：每個音檔轉完寫在旁邊的同名 .txt（錄音中每段完成就先轉，結束後不用重轉）
ap.add_argument("--files", nargs="*")
ap.add_argument("--hint", default="")   # 常用詞彙，用「、」分隔
a = ap.parse_args()
HINT = a.hint.strip()

if a.engine == "mlx" and HINT:
    # mlx_whisper 的 initial_prompt 只對每個檔案的第一個 30 秒視窗有效
    # （condition_on_previous_text=False 時之後的提示會被清空），
    # 所以改在每次解碼時，提示是空的就補上常用詞彙，整段錄音都吃得到
    import mlx_whisper
    _t = sys.modules["mlx_whisper.transcribe"]
    _DO = _t.DecodingOptions
    def _with_hint(**kw):
        if not kw.get("prompt"):
            kw["prompt"] = HINT
        return _DO(**kw)
    _t.DecodingOptions = _with_hint

if not a.files:
    if not a.audio_dir or not a.out:
        sys.exit("need --files or --audio-dir/--out")
    files = sorted(f for f in os.listdir(a.audio_dir) if f.endswith(".m4a"))
    if not files:
        sys.exit("no audio files")

def base_clock(name):
    try:
        return datetime.datetime.strptime(name[:6], "%H%M%S")
    except ValueError:
        return datetime.datetime(2000, 1, 1)

def segments(path):
    if a.engine == "mlx":
        import mlx_whisper
        r = mlx_whisper.transcribe(path, path_or_hf_repo=a.model, language=a.language,
                                   task="transcribe", temperature=0.0, condition_on_previous_text=False)
        for s in r["segments"]:
            yield s["start"], s["text"]
    elif a.engine == "faster-whisper":
        from faster_whisper import WhisperModel
        global _fw
        try:
            _fw
        except NameError:
            _fw = WhisperModel(a.model, device="auto", compute_type="auto")
        segs, _ = _fw.transcribe(path, language=a.language, vad_filter=True, condition_on_previous_text=False,
                                 hotwords=HINT or None)
        for s in segs:
            yield s.start, s.text
    else:
        sys.exit("unknown engine " + a.engine)

def lines(path):
    t0 = base_clock(os.path.basename(path))
    last = None
    for start, text in segments(path):
        text = text.strip()
        if not text or text == last:   # 模型在靜音時常重複同一句
            continue
        if HINT and len(text) > 4 and text.strip("、，。 ") in HINT:   # 靜音時把提示詞念出來
            continue
        last = text
        ts = (t0 + datetime.timedelta(seconds=start)).strftime("%H:%M:%S")
        yield f"[{ts}] {text}\n"

if a.files:
    for path in a.files:
        out = os.path.splitext(path)[0] + ".txt"
        with open(out + ".tmp", "w", encoding="utf-8") as fh:
            fh.writelines(lines(path))
        os.replace(out + ".tmp", out)   # 寫完才換名，沒轉完的不會被當成已轉好
        print("done", path, flush=True)
else:
    with open(a.out, "w", encoding="utf-8") as out:
        for f in files:
            out.writelines(lines(os.path.join(a.audio_dir, f)))
            out.flush()
            print("done", f, flush=True)
"""#
}
