import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var testResult = ""
    @State private var testing = false
    @State private var hintPreview = ""

    var body: some View {
        Form {
            Section("轉文字") {
                Picker("引擎", selection: $state.settings.engine) {
                    ForEach(EngineType.allCases) { Text($0.label).tag($0) }
                }
                if state.settings.engine.needsModel {
                    pathRow("模型資料夾", $state.settings.modelPath, directory: true)
                }
                if state.settings.engine.needsPython {
                    pathRow("Python（裝了對應套件的環境）", $state.settings.pythonPath, directory: false)
                }
                if state.settings.engine == .custom {
                    TextField("指令", text: $state.settings.customCommand, prompt: Text("whisper-cli -m {model} -f {audio} -otxt -of {out}"))
                    pathRow("模型（給 {model} 用，可留空）", $state.settings.modelPath, directory: false)
                    Text("{audio} 會換成 16kHz wav 音檔，{out} 是輸出文字檔路徑（工具會自己加 .txt 也可以）。").font(.caption).foregroundStyle(.secondary)
                }
                TextField("語言代碼", text: $state.settings.language)
                if state.settings.engine.perFile {
                    Toggle("錄音中就開始轉文字", isOn: $state.settings.liveTranscribe)
                    Text("每段錄音完成就先轉，另外每 2 分鐘轉一份即時草稿（會議助手用）。結束後只剩最後一段要轉。關掉的話，結束後才整場一起轉。").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(testing ? "測試中…" : "用一段中文測試音檔試跑") {
                        testing = true; testResult = ""
                        Task {
                            let r = await Transcriber.test(settings: state.settings)
                            testResult = (r.ok ? "✅ " : "❌ ") + r.message
                            testing = false
                        }
                    }.disabled(testing)
                }
                if !testResult.isEmpty { Text(testResult).font(.caption).textSelection(.enabled).lineLimit(6) }
            }

            Section("常用詞彙（人名、專案名、專有名詞）") {
                TextEditor(text: $state.settings.glossary)
                    .font(.body.monospaced()).frame(minHeight: 110)
                Text("一行一個，直接打詞就好。知道常被聽錯成什麼的，寫成「小名、曉明 > 曉銘」（錯的在左、對的在右，> 也可以打成 ->）：轉完文字會自動換掉。詞彙會當提示詞給語音模型，整理時也會交給 AI 當依據。只影響之後轉的文字，舊會議要按「重新轉文字」。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("標題含「人名」的那一區（例如 # 人名）每次都排最前面當提示；其他詞依最近 5 場出現與被換掉的次數自動挑，提示大約只放得下 120 字。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("看下一場會給語音模型哪些詞") {
                        hintPreview = Glossary(state.settings.glossary).asrHint(root: state.settings.outputRoot)
                        if hintPreview.isEmpty { hintPreview = "（詞彙表是空的）" }
                    }
                }
                if !hintPreview.isEmpty { Text(hintPreview).font(.caption).textSelection(.enabled) }
            }

            Section("AI") {
                Picker("預設使用", selection: $state.settings.provider) {
                    ForEach(Provider.allCases) { Text($0.label).tag($0) }
                }
                pathRow("claude 指令", $state.settings.claudePath, directory: false)
                ModelField(provider: .claude, value: $state.settings.claudeModel)
                pathRow("codex 指令", $state.settings.codexPath, directory: false)
                ModelField(provider: .codex, value: $state.settings.codexModel)
                TextField("Claude 執行時額外允許的工具（空白分隔，例如 Notion 的 MCP 名稱）", text: $state.settings.claudeExtraTools)
                Text("規劃階段只能讀檔；執行階段才允許寫檔、跑指令和這裡列的工具。").font(.caption).foregroundStyle(.secondary)
                Button("加入 skill 資料夾…") {
                    if let p = choose(directory: true) { state.settings.extraSkillDirs.append(p) }
                }
                ForEach(state.settings.extraSkillDirs, id: \.self) { d in
                    HStack { Text(d).font(.caption); Spacer()
                        Button("移除") { state.settings.extraSkillDirs.removeAll { $0 == d } } }
                }
            }

            Section("擷取") {
                pathRow("會議資料存放位置", $state.settings.outputRoot, directory: true)
                Stepper("每 \(Int(state.settings.captureInterval)) 秒截一次", value: $state.settings.captureInterval, in: 2...30)
                Stepper("錄音每 \(Int(state.settings.segmentSeconds / 60)) 分鐘存一段", value: $state.settings.segmentSeconds, in: 60...1800, step: 60)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func pathRow(_ label: String, _ value: Binding<String>, directory: Bool) -> some View {
        HStack {
            TextField(label, text: value)
            Button("選擇…") { if let p = choose(directory: directory) { value.wrappedValue = p } }
        }
    }

    private func choose(directory: Bool) -> String? {
        let p = NSOpenPanel()
        p.canChooseDirectories = directory
        p.canChooseFiles = !directory
        p.showsHiddenFiles = true
        p.treatsFilePackagesAsDirectories = true
        return p.runModal() == .OK ? p.url?.path : nil
    }
}

/// 模型欄位：Claude 給常用別名當快速選項，Codex 自由填（以 Codex 實際可用的名稱為準）；空白＝工具預設
struct ModelField: View {
    let provider: Provider
    @Binding var value: String

    var body: some View {
        HStack {
            TextField(provider == .claude ? "Claude 模型（空白＝預設）" : "Codex 模型（空白＝預設）", text: $value)
            if provider == .claude {
                Menu("常用") {
                    Button("預設") { value = "" }
                    ForEach(["opus", "sonnet", "haiku"], id: \.self) { m in Button(m) { value = m } }
                }.fixedSize()
            }
        }
    }
}
