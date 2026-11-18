import Foundation

/// 會議助手：會議中把即時逐字稿整理成重點（每累積 5 分鐘新內容增量更新一次），並回答使用者的問題。
/// 只把文字交給 AI（不給工具），用便宜的模型；整理結果存在會議資料夾的 assistant.json／assistant.md。
@MainActor
final class Assistant: ObservableObject {
    struct Point: Codable, Hashable { var text: String; var pending: Bool }
    struct Block: Codable, Hashable { var from: String; var to: String; var points: [String] }
    struct Message: Codable, Hashable, Identifiable {
        var id = UUID()
        var fromUser: Bool
        var text: String
    }
    struct Saved: Codable {
        var overview: [Point] = []
        var blocks: [Block] = []
        /// 已整理到逐字稿的哪個時間（當天秒數），-1＝還沒整理過
        var coveredUntil: Int = -1
        var chat: [Message] = []
    }

    let dir: URL
    @Published private(set) var saved = Saved()
    @Published private(set) var updating = false
    @Published private(set) var asking = false
    @Published var status = ""
    /// 逐字稿最新到哪個時間（給「重點更新到」旁邊對照）
    @Published private(set) var transcriptUntil: Int = -1

    /// 新內容累積到幾秒就自動整理一次
    static let stepSeconds = 300
    private var timer: Timer?
    private let settings: () -> Settings
    private let live: () -> Bool

    init(dir: URL, settings: @escaping () -> Settings, live: @escaping () -> Bool) {
        self.dir = dir; self.settings = settings; self.live = live
        if let d = try? Data(contentsOf: dir.appendingPathComponent("assistant.json")),
           let s = try? JSONDecoder().decode(Saved.self, from: d) { saved = s }
    }

    func start() {
        Task { await tick(force: saved.blocks.isEmpty) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick(force: false) }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: 逐字稿

    struct Line { let t: Int; let text: String }

    /// 目前的逐字稿：會議中用即時逐字稿，會後用正式逐字稿；都沒有就退回會議軟體字幕。兩路聲音都有時標上「線上／現場」
    func lines() -> [Line] {
        let names = live() ? ["live-transcript.txt", "live-transcript-mic.txt"] : ["transcript.txt", "transcript-mic.txt"]
        let both = names.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        var out: [Line] = []
        for (i, n) in names.enumerated() {
            let tag = both ? (i == 0 ? "（線上）" : "（現場）") : ""
            out += parse(MeetingFiles.read(dir, n), tag: tag)
        }
        if out.isEmpty {
            out = parse(MeetingFiles.read(dir, "captions.txt"), tag: "（字幕）").filter { !$0.text.contains("<<畫面") }
        }
        return out.sorted { $0.t < $1.t }
    }

    private func parse(_ text: String, tag: String) -> [Line] {
        text.split(separator: "\n").compactMap { l in
            guard let t = Clock.parse(l) else { return nil }
            let body = l.dropFirst(10).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : Line(t: t, text: "[\(l.dropFirst().prefix(8))]\(tag) \(body)")
        }
    }

    // MARK: 重點整理

    /// force＝不管累積多少，有新內容就整理（第一次打開、按「立即更新」）
    func tick(force: Bool) async {
        guard !updating else { return }
        let all = lines()
        transcriptUntil = all.last?.t ?? -1
        let fresh = all.filter { $0.t > saved.coveredUntil }
        guard let last = fresh.last else {
            if saved.blocks.isEmpty { status = live() ? "還沒有逐字稿：第一份草稿約在開始錄音 2 分鐘後出來" : "這場沒有逐字稿" }
            return
        }
        let span = last.t - max(saved.coveredUntil, fresh.first!.t)
        guard force || saved.coveredUntil < 0 || span >= Self.stepSeconds else { return }
        updating = true; status = saved.blocks.isEmpty ? "正在整理到目前為止的重點…" : "正在更新重點…"
        defer { updating = false }
        do {
            let r = try await summarize(fresh)
            saved.overview = r.overview
            saved.blocks += r.blocks
            saved.coveredUntil = last.t
            status = ""
            persist()
        } catch {
            status = "整理失敗：\(error.localizedDescription.prefix(200))"
        }
    }

    private struct SummaryResponse: Codable { var overview: [Point]; var blocks: [Block] }

    private func summarize(_ fresh: [Line]) async throws -> SummaryResponse {
        let s = settings()
        let prev = saved.overview.isEmpty ? "（還沒有）" : saved.overview.map { ($0.pending ? "［待確認］" : "") + $0.text }.joined(separator: "\n")
        let prompt = """
        你是會議中的筆記助手。下面是會議逐字稿「新增的部分」（語音辨識結果，可能有同音錯字），以及上一版的「目前結論與待確認」。
        \(context(s))
        上一版的目前結論與待確認：
        \(prev)

        新增的逐字稿：
        \(fresh.map(\.text).joined(separator: "\n"))

        請回傳 JSON：
        - blocks：把新增的逐字稿依時間切成約 5 分鐘一段（不足 5 分鐘就一段），每段 from／to 用「HH:MM」，points 是 1～4 條重點，每條一句話、說人話，誰說的有把握就寫上名字。沒有實質內容的段落（寒暄、等人、沒聲音）points 給空陣列。
        - overview：整場到目前為止的「目前結論與待確認」，最多 6 條，整合上一版和新內容後整份重寫；已經有共識的 pending=false，還沒結論、待確認、有人要回頭查的 pending=true。
        只根據逐字稿，不要編造。
        """
        let data = try await Self.ask(prompt: prompt, schema: Self.summarySchema, dir: dir, settings: s)
        return try JSONDecoder().decode(SummaryResponse.self, from: data)
    }

    // MARK: 討論

    func ask(_ question: String) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        saved.chat.append(Message(fromUser: true, text: q))
        asking = true; persist()
        defer { asking = false }
        let s = settings()
        // 逐字稿太長時只取後面（約 4 萬字），前面靠重點整理補
        var transcript = lines().map(\.text).joined(separator: "\n")
        if transcript.count > 40_000 { transcript = "（前面省略，請參考重點整理）\n" + transcript.suffix(40_000) }
        let history = saved.chat.dropLast().suffix(6).map { ($0.fromUser ? "使用者：" : "助手：") + $0.text }.joined(separator: "\n")
        let prompt = """
        你是會議中的助手，使用者正在開會，想快速搞清楚剛剛講了什麼。根據逐字稿回答，簡短直接（3～6 句或條列），附上時間點（例如「約 10:32」）。逐字稿沒提到就直說沒提到，不要編造。逐字稿是語音辨識結果，可能有同音錯字。
        \(context(s))
        \(s.myName.isEmpty ? "" : "使用者的名字是「\(s.myName)」（逐字稿裡可能出現同音字）。\n")
        目前的重點整理：
        \(markdown())

        到目前為止的逐字稿：
        \(transcript)
        \(history.isEmpty ? "" : "\n前面的對話：\n\(history)\n")
        使用者的問題：\(q)
        """
        do {
            let data = try await Self.ask(prompt: prompt, schema: #"{"type":"object","additionalProperties":false,"required":["answer"],"properties":{"answer":{"type":"string"}}}"#, dir: dir, settings: s)
            let answer = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["answer"] as? String ?? "（沒有回答）"
            saved.chat.append(Message(fromUser: false, text: answer))
        } catch {
            saved.chat.append(Message(fromUser: false, text: "回答失敗：\(error.localizedDescription.prefix(300))"))
        }
        persist()
    }

    private func context(_ s: Settings) -> String {
        var parts: [String] = []
        let title = MeetingFiles.title(dir)
        if !title.isEmpty { parts.append("會議標題：\(title)") }
        let notes = MeetingFiles.read(dir, "notes.md").trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("會議說明（以這段為準）：\n\(notes)") }
        let g = Glossary(s.glossary).promptBlock
        if !g.isEmpty { parts.append(g) }
        return parts.isEmpty ? "" : "\n" + parts.joined(separator: "\n\n") + "\n"
    }

    // MARK: 存檔

    func markdown() -> String {
        var md = "## 目前結論與待確認\n"
        md += saved.overview.isEmpty ? "（還沒有）\n" : saved.overview.map { "- " + ($0.pending ? "［待確認］" : "") + $0.text }.joined(separator: "\n") + "\n"
        for b in saved.blocks.reversed() where !b.points.isEmpty {
            md += "\n## \(b.from)–\(b.to)\n" + b.points.map { "- " + $0 }.joined(separator: "\n") + "\n"
        }
        return md
    }

    private func persist() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? enc.encode(saved).write(to: dir.appendingPathComponent("assistant.json"))
        MeetingFiles.write(dir, "assistant.md", "# 會議助手整理（會議中產生）\n\n" + markdown())
    }

    /// 命令列驗證用：整理一次、可選擇再問一題，回傳 markdown
    static func runOnce(dir: URL, settings: Settings, question: String?) async -> String {
        let a = Assistant(dir: dir, settings: { settings }, live: { false })
        await a.tick(force: true)
        var out = a.status.isEmpty ? "" : "狀態：\(a.status)\n"
        out += a.markdown()
        if let q = question {
            await a.ask(q)
            out += "\n\n問：\(q)\n答：\(a.saved.chat.last?.text ?? "")"
        }
        return out
    }

    // MARK: 呼叫 AI（純文字，不給工具）

    static func ask(prompt: String, schema: String, dir: URL, settings s: Settings) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            switch s.provider {
            case .claude:
                guard !s.claudePath.isEmpty else { throw AIError.notConfigured("找不到 claude 指令，請在設定裡指定路徑") }
                var args = ["-p", prompt, "--output-format", "json", "--json-schema", schema, "--tools", ""]
                let model = s.assistantModel.isEmpty ? s.claudeModel : s.assistantModel
                if !model.isEmpty { args += ["--model", model] }
                let r = Shell.run(s.claudePath, args, cwd: dir, env: Shell.loginEnv)
                guard r.code == 0 else { throw AIError.failed("exit \(r.code)\n" + String((r.err + "\n" + r.out).suffix(800))) }
                guard let outer = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any] else { throw AIError.badJSON(String(r.out.prefix(300))) }
                if (outer["is_error"] as? Bool) == true { throw AIError.failed(outer["result"] as? String ?? r.out) }
                if let so = outer["structured_output"], let d = try? JSONSerialization.data(withJSONObject: so) { return d }
                if let t = outer["result"] as? String, let d = AIRunner.extractJSON(t) { return d }
                throw AIError.badJSON(String(r.out.prefix(300)))
            case .codex:
                guard !s.codexPath.isEmpty else { throw AIError.notConfigured("找不到 codex 指令，請在設定裡指定路徑") }
                let schemaURL = Resources.write(name: "schema-\(UUID().uuidString).json", content: schema)
                let lastURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-last-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: schemaURL); try? FileManager.default.removeItem(at: lastURL) }
                var args = ["exec", "--skip-git-repo-check", "-C", dir.path, "--sandbox", "read-only"]
                let model = s.assistantModel.isEmpty ? s.codexModel : s.assistantModel
                if !model.isEmpty { args += ["-m", model] }
                args += ["--output-schema", schemaURL.path, "-o", lastURL.path, prompt]
                let r = Shell.run(s.codexPath, args, cwd: dir, env: Shell.loginEnv)
                guard r.code == 0 else { throw AIError.failed("exit \(r.code)\n" + String((r.err + "\n" + r.out).suffix(800))) }
                guard let t = try? String(contentsOf: lastURL, encoding: .utf8), let d = AIRunner.extractJSON(t) else { throw AIError.badJSON(String(r.out.suffix(300))) }
                return d
            }
        }.value
    }

    static let summarySchema = #"""
    {"type":"object","additionalProperties":false,"required":["overview","blocks"],
     "properties":{
      "overview":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["text","pending"],
        "properties":{"text":{"type":"string"},"pending":{"type":"boolean"}}}},
      "blocks":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["from","to","points"],
        "properties":{"from":{"type":"string"},"to":{"type":"string"},"points":{"type":"array","items":{"type":"string"}}}}}
     }}
    """#
}
