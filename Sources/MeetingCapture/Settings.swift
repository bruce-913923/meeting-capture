import Foundation

enum EngineType: String, Codable, CaseIterable, Identifiable {
    case mlx, fasterWhisper = "faster-whisper", custom, apple
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mlx: return "MLX Whisper（例如 Breeze-ASR-25，Apple Silicon）"
        case .fasterWhisper: return "faster-whisper"
        case .custom: return "自訂指令（whisper.cpp 等任何工具）"
        case .apple: return "macOS 內建語音辨識（免模型，準確度較低）"
        }
    }
    var needsModel: Bool { self == .mlx || self == .fasterWhisper }
    var needsPython: Bool { self == .mlx || self == .fasterWhisper }
    /// 可以逐檔轉、錄音中邊錄邊轉
    var perFile: Bool { self == .mlx || self == .fasterWhisper }
}

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var label: String { self == .claude ? "Claude（claude -p）" : "Codex（codex exec）" }
}

struct Settings: Codable, Equatable {
    init() {}
    var outputRoot: String = NSHomeDirectory() + "/MeetingCapture"
    var captureInterval: Double = 4
    var segmentSeconds: Double = 600

    var engine: EngineType = .mlx
    var modelPath: String = ""
    var pythonPath: String = ""
    var language: String = "zh"
    /// 自訂指令：{audio} 換成音檔、{out} 換成輸出文字檔路徑（不含副檔名或含 .txt 皆可）、{model} 換成模型路徑
    var customCommand: String = ""

    var provider: Provider = .claude
    var claudePath: String = ""
    var codexPath: String = ""
    /// 空白＝用該工具自己的預設模型
    var claudeModel: String = ""
    var codexModel: String = ""
    /// 結束後的動作：「builtin」＝內建預設會議文章；否則是 skill 的 SKILL.md 路徑
    var action: String = "builtin"
    var extraSkillDirs: [String] = []
    /// 執行階段額外允許 Claude 使用的工具（例如 Notion MCP），空白分隔
    var claudeExtraTools: String = ""
    /// 執行階段允許使用的 MCP 連線（`claude mcp list` 的名稱）
    var allowedMCP: [String] = []
    /// 產出類型：summary / minutes / article / custom
    var outputKind: String = "summary"
    /// 常用詞彙（見 Glossary）
    var glossary: String = ""
    /// 錄音中就開始轉文字（每段完成就轉，另有每 2 分鐘的即時草稿）；只有 MLX／faster-whisper 支援
    var liveTranscribe: Bool = true

    /// 舊版設定檔少了新欄位時用預設值補上
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil ?? d }
        outputRoot = v(.outputRoot, outputRoot); captureInterval = v(.captureInterval, captureInterval)
        segmentSeconds = v(.segmentSeconds, segmentSeconds); engine = v(.engine, engine)
        modelPath = v(.modelPath, modelPath); pythonPath = v(.pythonPath, pythonPath)
        language = v(.language, language); customCommand = v(.customCommand, customCommand)
        provider = v(.provider, provider); claudePath = v(.claudePath, claudePath); codexPath = v(.codexPath, codexPath)
        claudeModel = v(.claudeModel, claudeModel); codexModel = v(.codexModel, codexModel)
        action = v(.action, action); extraSkillDirs = v(.extraSkillDirs, extraSkillDirs)
        claudeExtraTools = v(.claudeExtraTools, claudeExtraTools)
        allowedMCP = v(.allowedMCP, allowedMCP); outputKind = v(.outputKind, outputKind)
        glossary = v(.glossary, glossary)
        liveTranscribe = v(.liveTranscribe, liveTranscribe)
    }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingCapture")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    static func load() -> Settings {
        guard let d = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings().withDefaults() }
        return s.withDefaults()
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? enc.encode(self).write(to: Self.fileURL)
    }

    /// 第一次啟動時自動找常見位置；找不到就留空讓使用者挑
    func withDefaults() -> Settings {
        var s = self
        if s.claudePath.isEmpty { s.claudePath = Shell.which("claude") ?? "" }
        if s.codexPath.isEmpty { s.codexPath = Shell.which("codex") ?? "" }
        // 本機預設值（模型、Python 路徑等）放在 app 裡的 defaults.json，由 make-app.sh 從 config.local.json 複製進來；不進版控
        if let url = Bundle.main.url(forResource: "defaults", withExtension: "json"),
           let d = try? Data(contentsOf: url),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            func pick(_ k: String) -> String? {
                guard let v = (j[k] as? String)?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
                return (v as NSString).expandingTildeInPath
            }
            func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
            if s.modelPath.isEmpty, let v = pick("modelPath"), exists(v) { s.modelPath = v }
            if s.pythonPath.isEmpty, let v = pick("pythonPath"), exists(v) { s.pythonPath = v }
            if s.glossary.isEmpty, let v = j["glossary"] as? String { s.glossary = v }
        }
        return s
    }
}

enum Shell {
    /// GUI app 沒有使用者的 PATH，透過登入 shell 找指令
    static func which(_ cmd: String) -> String? {
        let r = run("/bin/zsh", ["-lc", "command -v \(cmd)"])
        let p = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.code == 0 && p.hasPrefix("/") ? p : nil
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = env }
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        p.standardInput = FileHandle.nullDevice
        // 兩路輸出同時讀：只讀一路時，另一路塞滿管線會讓子程序卡住（codex 的錯誤輸出量很大）
        let lock = NSLock()
        var outData = Data(), errData = Data()
        let maxErr = 200_000
        o.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; lock.lock(); outData.append(d); lock.unlock()
        }
        e.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; lock.lock(); errData.append(d)
            if errData.count > maxErr * 2 { errData = errData.suffix(maxErr) }
            lock.unlock()
        }
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        p.waitUntilExit()
        // 收尾：給管線 0.3 秒把剩下的資料送完；不等管線關閉，避免背景程序握著管線時卡住
        Thread.sleep(forTimeInterval: 0.3)
        o.fileHandleForReading.readabilityHandler = nil
        e.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        lock.unlock()
        return (p.terminationStatus, out, err)
    }

    /// 登入 shell 的環境變數（PATH 等），給 claude / codex 子程序用
    static let loginEnv: [String: String] = {
        let r = run("/bin/zsh", ["-lc", "env"])
        var env = ProcessInfo.processInfo.environment
        for line in r.out.split(separator: "\n") {
            if let i = line.firstIndex(of: "=") { env[String(line[..<i])] = String(line[line.index(after: i)...]) }
        }
        return env
    }()
}
