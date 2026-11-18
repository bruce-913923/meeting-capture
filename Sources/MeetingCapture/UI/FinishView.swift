import SwiftUI

/// 結束後的整理視窗：選整理方式 → AI 規劃出題 → 使用者回答 → AI 執行 → 顯示結果。
/// 題目全部來自 AI 回傳的 JSON，app 只負責畫。
struct FinishView: View {
    let dir: URL
    @EnvironmentObject var state: AppState

    enum Step { case choose, planning, answering(PlanResponse), executing, done(ExecuteResponse), failed(String) }
    @State private var step: Step = .choose
    @State private var skills: [SkillInfo] = []
    @State private var skillID = "builtin"
    @State private var showAll = false
    @State private var answers: [String: String] = [:]
    @State private var multi: [String: Set<String>] = [:]
    @State private var title = ""
    @State private var notes = ""
    @State private var request = ""
    @State private var servers: [MCPServer] = []
    @State private var loadingServers = false
    /// 整理完 AI 回報的聽錯詞，使用者勾選要加進常用詞彙的
    @State private var pickedFixes: Set<ExecuteResponse.Correction> = []
    @State private var addedFixes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            switch step {
            case .choose: chooseView
            case .planning: progress("AI 正在看會議內容，準備要問你的問題…")
            case .answering(let plan): answerView(plan)
            case .executing: progress("AI 正在整理並輸出，通常要幾分鐘…")
            case .done(let r): doneView(r)
            case .failed(let msg): failedView(msg)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 640)
        .onAppear {
            loadSkills()
            title = MeetingFiles.title(dir); notes = MeetingFiles.read(dir, "notes.md"); request = MeetingFiles.read(dir, "request.md")
            loadServers()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dir.lastPathComponent).font(.headline)
            HStack(spacing: 12) {
                Text(fileStatus("transcript.txt", "電腦聲音逐字稿"))
                Text(fileStatus("transcript-mic.txt", "麥克風逐字稿"))
                Text(fileStatus("captions.txt", "字幕"))
                Text("簡報 \(countFiles("slides", ext: "jpg")) 張")
                Button("打開資料夾") { state.openFolder(dir) }.buttonStyle(.link)
            }.font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("在 \(state.providerName) 討論這場會議") { state.discuss(dir: dir, resume: false) }
                if Discussion.hasPrevious(dir) {
                    Button("繼續上次的討論") { state.discuss(dir: dir, resume: true) }
                }
            }.font(.caption)
        }
    }

    // MARK: 選擇整理方式

    private var chooseView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("這場會議") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("會議名稱", text: $title)
                        Text("會議說明：背景、與會者、想討論什麼、專有名詞。AI 理解內容時以這段為準。").font(.caption).foregroundStyle(.secondary)
                        editor($notes, placeholder: "例如：新功能需求討論，與會者小明（PO）、阿華（工程師）。主要決定這一輪要做哪幾項。", height: 80)
                    }.padding(4)
                }

                GroupBox("要產出什麼") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $state.settings.outputKind) {
                            ForEach(OutputKind.allCases) { Text($0.label).tag($0.rawValue) }
                        }.pickerStyle(.radioGroup).labelsHidden()
                        Text("這次的額外要求（可留空）").font(.caption).foregroundStyle(.secondary)
                        editor($request, placeholder: "例如：只要條列結論跟討論重點，不用寫背景；待辦要標負責人。", height: 60)
                    }.padding(4)
                }

                GroupBox("放到哪裡、用哪個 AI") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("整理方式", selection: $skillID) {
                            ForEach(visibleSkills) { s in Text(s.id == "builtin" ? "只存在本機（Markdown 檔）" : "\(s.name)（\(s.source)）").tag(s.id) }
                        }
                        Toggle("顯示所有 skill（預設只列跟會議或筆記有關的）", isOn: $showAll).font(.caption)
                        if let s = skills.first(where: { $0.id == skillID }), s.id != "builtin" {
                            Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Picker("用哪個 AI", selection: $state.settings.provider) {
                            ForEach(Provider.allCases) { Text($0.label).tag($0) }
                        }
                        .onChange(of: state.settings.provider) { _, _ in loadSkills() }
                        if state.settings.provider == .claude {
                            ModelField(provider: .claude, value: $state.settings.claudeModel)
                        } else {
                            ModelField(provider: .codex, value: $state.settings.codexModel)
                        }
                    }.padding(4)
                }

                if state.settings.provider == .claude { serverBox }

                HStack {
                    Spacer()
                    Button("開始整理") { Task { await plan() } }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// 執行階段允許的外部連線（Notion 等）。沒勾就會被擋下。
    private var serverBox: some View {
        GroupBox("執行時允許使用的連線") {
            VStack(alignment: .leading, spacing: 6) {
                if loadingServers {
                    HStack { ProgressView().controlSize(.small); Text("正在查命令列 claude 的連線…").font(.caption) }
                } else if servers.isEmpty {
                    Text("命令列 claude 沒有設定任何連線。").font(.caption)
                }
                ForEach(servers) { m in
                    Toggle(isOn: Binding(
                        get: { state.settings.allowedMCP.contains(m.name) },
                        set: { on in
                            if on { if !state.settings.allowedMCP.contains(m.name) { state.settings.allowedMCP.append(m.name) } }
                            else { state.settings.allowedMCP.removeAll { $0 == m.name } }
                        })) {
                        Text(m.name + (m.connected ? "" : "（尚未授權，勾了也不能用）"))
                    }.disabled(!m.usable && !state.settings.allowedMCP.contains(m.name))
                }
                if let w = connectionWarning {
                    Text("⚠️ " + w).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("要寫進 Notion 等外部服務，這裡要勾對應的連線；同一個服務有兩個連線時勾一個就會一起放行。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新檢查") { loadServers() }.font(.caption)
                }
            }.padding(4)
        }
    }

    /// 選的 skill 看起來要用 Notion，卻沒勾可用的 Notion 連線
    private var connectionWarning: String? {
        guard let s = skills.first(where: { $0.id == skillID }), s.id != "builtin" else { return nil }
        let text = (s.name + s.description).lowercased()
        guard text.contains("notion") else { return nil }
        let ok = servers.contains { $0.usable && $0.service == "notion" && state.settings.allowedMCP.contains($0.name) }
        if ok { return nil }
        let unauth = servers.filter { !$0.connected && $0.service == "notion" }.map(\.name)
        if !unauth.isEmpty && !servers.contains(where: { $0.usable && $0.service == "notion" }) {
            return "這個整理方式會寫進 Notion，但「\(unauth.joined(separator: "、"))」還沒授權，執行時會被擋下。請在終端機輸入 claude，進去後打 /mcp，選它完成登入，再按「重新檢查」並勾選。"
        }
        if servers.contains(where: { $0.usable && $0.service == "notion" }) {
            return "這個整理方式會寫進 Notion，請勾選上面的 Notion 連線，不然執行時會被擋下。"
        }
        return "這個整理方式會寫進 Notion，但命令列 claude 沒有可用的 Notion 連線，執行時會被擋下。"
    }

    private func editor(_ text: Binding<String>, placeholder: String, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text).font(.body).frame(height: height)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            if text.wrappedValue.isEmpty {
                Text(placeholder).font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 1).allowsHitTesting(false)
            }
        }
    }

    private var visibleSkills: [SkillInfo] {
        showAll ? skills : skills.filter { SkillScanner.isMeetingRelated($0) || $0.id == skillID }
    }

    // MARK: AI 出的題目

    private func answerView(_ plan: PlanResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(plan.summary).font(.callout)
                ForEach(plan.questions) { q in questionView(q) }
                HStack {
                    Button("重新規劃") { Task { await self.plan() } }
                    Spacer()
                    Button("確認並執行") { Task { await execute(plan) } }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder
    private func questionView(_ q: PlanResponse.Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(q.label).bold()
            if let h = q.help, !h.isEmpty { Text(h).font(.caption).foregroundStyle(.secondary) }
            switch q.type {
            case "single":
                Picker("", selection: binding(q.id)) {
                    ForEach(q.options ?? [], id: \.value) { o in
                        Text(o.label + ((o.recommended ?? false) ? "（推薦）" : "")).tag(o.value)
                    }
                }.pickerStyle(.radioGroup).labelsHidden()
            case "multi":
                ForEach(q.options ?? [], id: \.value) { o in
                    Toggle(o.label + ((o.recommended ?? false) ? "（推薦）" : ""), isOn: Binding(
                        get: { multi[q.id, default: []].contains(o.value) },
                        set: { on in
                            if on { multi[q.id, default: []].insert(o.value) } else { multi[q.id, default: []].remove(o.value) }
                        }))
                }
            case "confirm":
                Toggle("是", isOn: Binding(get: { answers[q.id] == "是" }, set: { answers[q.id] = $0 ? "是" : "否" }))
            default:
                TextField("", text: binding(q.id))
            }
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }

    // MARK: 結果

    private func doneView(_ r: ExecuteResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(r.status == "ok" ? "✅ 完成" : "⚠️ 沒有完成").font(.title3)
            Text(r.summary)
            if let u = r.url, let url = URL(string: u) { Link("打開頁面：\(u)", destination: url) }
            if let p = r.outputPath { Button("打開檔案：\(p)") { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }.buttonStyle(.link) }
            let fixes = newCorrections(r)
            if !fixes.isEmpty {
                GroupBox("AI 認為逐字稿聽錯的詞：勾選的會加進常用詞彙，下次轉文字自動換掉") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(fixes, id: \.self) { c in
                            Toggle("\(c.wrong) > \(c.right)　（\(c.kind)）", isOn: Binding(
                                get: { pickedFixes.contains(c) },
                                set: { on in if on { pickedFixes.insert(c) } else { pickedFixes.remove(c) } }))
                        }
                        HStack {
                            Text(addedFixes ? "已加入，可到 設定 › 常用詞彙 修改" : "常見詞不要勾，替換時會誤傷其他句子")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("加入常用詞彙") {
                                var g = state.settings.glossary
                                for c in fixes where pickedFixes.contains(c) {
                                    g = Glossary.adding(g, wrong: c.wrong, right: c.right, kind: c.kind)
                                }
                                state.settings.glossary = g
                                addedFixes = true
                            }.disabled(pickedFixes.isEmpty || addedFixes)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { if pickedFixes.isEmpty && !addedFixes { pickedFixes = Set(fixes) } }
            }
            HStack { Spacer(); Button("改需求再整理一次") { addedFixes = false; pickedFixes = []; step = .choose } }
        }
    }

    /// 詞彙表裡還沒有的修正
    private func newCorrections(_ r: ExecuteResponse) -> [ExecuteResponse.Correction] {
        let g = Glossary(state.settings.glossary)
        var seen = Set<String>()
        return (r.corrections ?? []).filter { c in
            let w = c.wrong.trimmingCharacters(in: .whitespaces), rt = c.right.trimmingCharacters(in: .whitespaces)
            guard !w.isEmpty, !rt.isEmpty, w != rt, !g.knows(wrong: w, right: rt), seen.insert(w).inserted else { return false }
            return true
        }
    }

    private func failedView(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("⚠️ 出錯了").font(.title3)
            ScrollView { Text(msg).font(.caption).textSelection(.enabled) }.frame(maxHeight: 220)
            HStack { Spacer(); Button("回到上一步") { step = .choose } }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 10) { ProgressView().controlSize(.small); Text(text) }
    }

    // MARK: 動作

    private func loadSkills() {
        skills = SkillScanner.scan(provider: state.settings.provider, extraDirs: state.settings.extraSkillDirs)
        skillID = skills.contains { $0.id == state.settings.action } ? state.settings.action : "builtin"
    }

    private func loadServers() {
        loadingServers = true
        let path = state.settings.claudePath
        Task.detached {
            let list = MCPServer.list(claudePath: path)
            await MainActor.run { servers = list; loadingServers = false }
        }
    }

    /// 把畫面上填的東西存回會議資料夾，組成給 AI 的需求
    private func saveContext() -> RunContext {
        MeetingFiles.write(dir, "notes.md", notes)
        MeetingFiles.write(dir, "request.md", request)
        if !title.isEmpty { MeetingFiles.setTitle(dir, title) }
        let tools = state.settings.provider == .claude
            ? MCPServer.allowedPrefixes(servers: servers, checked: state.settings.allowedMCP) : []
        return RunContext(title: title, notes: notes, kind: OutputKind(rawValue: state.settings.outputKind) ?? .summary,
                          request: request, mcpTools: tools, glossary: state.settings.glossary)
    }

    private func plan() async {
        guard let skill = skills.first(where: { $0.id == skillID }) else { return }
        state.settings.action = skillID
        let ctx = saveContext()
        step = .planning
        do {
            let p = try await AIRunner.plan(dir: dir, skill: skill, context: ctx, settings: state.settings)
            answers = [:]; multi = [:]
            for q in p.questions {
                if let rec = q.options?.first(where: { $0.recommended ?? false }) {
                    if q.type == "multi" { multi[q.id] = [rec.value] } else { answers[q.id] = rec.value }
                } else if q.type == "confirm" {
                    let d = (q.defaultValue ?? "").lowercased()
                    answers[q.id] = ["true", "yes", "是", "1"].contains(d) ? "是" : "否"
                } else if let d = q.defaultValue { answers[q.id] = d }
            }
            step = .answering(p)
        } catch { step = .failed(error.localizedDescription) }
    }

    private func execute(_ plan: PlanResponse) async {
        guard let skill = skills.first(where: { $0.id == skillID }) else { return }
        var all: [String: String] = [:]
        for q in plan.questions {
            let v = q.type == "multi" ? multi[q.id, default: []].sorted().joined(separator: "、") : (answers[q.id] ?? "")
            all["\(q.label)（\(q.id)）"] = v
        }
        let ctx = saveContext()
        step = .executing
        do {
            let r = try await AIRunner.execute(dir: dir, skill: skill, answers: all, context: ctx, settings: state.settings)
            step = .done(r)
            state.notify(r.status == "ok" ? "會議整理完成" : "會議整理沒有完成", r.summary)
        } catch { step = .failed(error.localizedDescription) }
    }

    private func fileStatus(_ name: String, _ label: String) -> String {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) ? "\(label) ✓" : "\(label) ✗"
    }

    private func countFiles(_ sub: String, ext: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(sub).path)) ?? [])
            .filter { $0.hasSuffix(ext) }.count
    }
}
