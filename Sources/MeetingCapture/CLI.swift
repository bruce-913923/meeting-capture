import Foundation

/// 開發與驗證用的命令列模式（不開介面）：
///   MeetingCapture --cli test-transcribe
///   MeetingCapture --cli transcribe <會議資料夾>
///   MeetingCapture --cli live <會議資料夾>   （模擬錄音中：轉草稿與最後一段以外的段落，印出即時逐字稿）
///   MeetingCapture --cli skills
///   MeetingCapture --cli plan <會議資料夾> [skill 路徑或 builtin] [claude|codex]
///   MeetingCapture --cli execute <會議資料夾> <skill> <provider> <答案 JSON>
///   MeetingCapture --cli detect <截圖檔>
enum CLI {
    static func runIfRequested() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--cli"), i + 1 < a.count else { return }
        let cmd = a[i + 1]
        let rest = Array(a.dropFirst(i + 2))
        // 不能用 semaphore 卡住主執行緒：會議助手等 @MainActor 的東西要在主執行緒上跑
        var done = false
        Task {
            await run(cmd, rest)
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        exit(0)
    }

    private static func run(_ cmd: String, _ args: [String]) async {
        var settings = Settings.load()
        func skill(_ id: String?) -> SkillInfo {
            guard let id, id != "builtin" else { return SkillScanner.builtin }
            return SkillScanner.scan(provider: settings.provider, extraDirs: settings.extraSkillDirs).first { $0.id == id || $0.name == id }
                ?? SkillInfo(id: id, name: URL(fileURLWithPath: id).deletingLastPathComponent().lastPathComponent, description: "", source: "自訂")
        }
        if args.count > 2, let p = Provider(rawValue: args[2]) { settings.provider = p }
        do {
            switch cmd {
            case "test-transcribe":
                let r = await Transcriber.test(settings: settings)
                print(r.ok ? "OK" : "FAIL", r.message)
            case "transcribe":
                try await Transcriber.transcribe(dir: URL(fileURLWithPath: args[0]), settings: settings)
                print("OK")
            case "live":
                let dir = URL(fileURLWithPath: args[0])
                for (sub, _) in Transcriber.sources {
                    let segs = Transcriber.segments(dir.appendingPathComponent(sub)).dropLast()
                    let drafts = Transcriber.segments(dir.appendingPathComponent("live").appendingPathComponent(sub))
                    for f in Array(segs) + drafts { _ = await Transcriber.runLive(file: f, dir: dir, settings: settings) }
                    if let n = Transcriber.liveNames[sub] { print("== \(n)"); print((try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)) ?? "") }
                }
            case "discuss-script":
                // 印出討論用的腳本路徑（不開終端機）；args[1] 可指定替代執行檔，方便測試
                if args.count > 1 { settings.claudePath = args[1]; settings.codexPath = args[1] }
                let url = try Discussion.makeScript(dir: URL(fileURLWithPath: args[0]), settings: settings, live: false, resume: false)
                print(url.path)
            case "assistant":
                // 會議助手：整理到目前為止的重點；有第二個參數就再問一題
                let dir = URL(fileURLWithPath: args[0])
                let out = await Assistant.runOnce(dir: dir, settings: settings, question: args.count > 1 ? args[1] : nil)
                print(out)
            case "skills":
                for s in SkillScanner.scan(provider: settings.provider, extraDirs: settings.extraSkillDirs) {
                    print(SkillScanner.isMeetingRelated(s) ? "*" : " ", s.source, s.name, "—", s.id)
                }
            case "plan":
                let dir = URL(fileURLWithPath: args[0])
                let p = try await AIRunner.plan(dir: dir, skill: skill(args.count > 1 ? args[1] : nil), context: RunContext.load(dir: dir, settings: settings), settings: settings)
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                print(String(data: try enc.encode(p), encoding: .utf8)!)
            case "execute":
                let answers = (try JSONSerialization.jsonObject(with: Data(args[3].utf8)) as? [String: String]) ?? [:]
                let dir = URL(fileURLWithPath: args[0])
                let r = try await AIRunner.execute(dir: dir, skill: skill(args[1]), answers: answers, context: RunContext.load(dir: dir, settings: settings), settings: settings)
                print(r.status, r.summary, r.url ?? "", r.outputPath ?? "")
                for c in r.corrections ?? [] { print("修正：", c.wrong, ">", c.right, "（\(c.kind)）") }
            case "import":
                let dir = try await VideoImporter.run(video: URL(fileURLWithPath: args[0]), settings: settings) { f, m in
                    FileHandle.standardError.write("\r\(Int(f * 100))% \(m)        ".data(using: .utf8)!)
                }
                print("\n" + dir.path)
            case "mcp":
                let list = MCPServer.list(claudePath: settings.claudePath)
                for m in list { print(m.connected ? "✔" : "✗", m.name, "→", m.toolPrefix, "|", m.status) }
                print("執行時會放行：", MCPServer.allowedPrefixes(servers: list, checked: settings.allowedMCP).joined(separator: " "))
            case "detect":
                print("use the standalone test")
            default:
                print("unknown command")
            }
        } catch {
            print("ERROR", error.localizedDescription)
        }
    }
}
