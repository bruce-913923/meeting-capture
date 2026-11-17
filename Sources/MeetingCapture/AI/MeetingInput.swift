import Foundation

/// 產出類型：決定內容的格式與篇幅（放到哪裡仍照整理方式／skill）
enum OutputKind: String, CaseIterable, Identifiable {
    case summary, minutes, article, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .summary: return "會議摘要：條列結論與討論重點（小會議）"
        case .minutes: return "會議紀錄：決議、待辦、各議題討論（專案會議）"
        case .article: return "分享文章：吸收後寫成文章，配簡報圖（技術分享）"
        case .custom: return "自訂：完全照我下面寫的要求"
        }
    }
    var fileName: String {
        switch self {
        case .summary: return "summary.md"
        case .minutes: return "minutes.md"
        case .article: return "article.md"
        case .custom: return "output.md"
        }
    }
    /// 給 AI 的格式規則
    var rules: String {
        switch self {
        case .summary: return """
            會議摘要：給沒參加的人一分鐘看懂。結構固定為
            1. 一句話：這場會議在談什麼
            2. 結論（條列，每點一句，寫清楚決定了什麼）
            3. 討論重點（條列，依議題分組，每點一兩句；有不同意見要寫出來）
            4. 待辦（有才寫：誰、做什麼、何時）
            5. 還沒定的事（有才寫）
            不寫背景長文、不寫講者介紹、不放簡報圖（除非沒有圖就看不懂）。整份控制在一頁內。
            """
        case .minutes: return """
            會議紀錄：給專案成員追蹤用。結構固定為
            1. 決議（條列）
            2. 待辦（表格：負責人、事項、期限；逐字稿聽不出負責人就寫「未指定」）
            3. 各議題討論摘要（每個議題一小段，寫出提出的問題、討論過的選項、為什麼這樣決定）
            4. 還沒定的事與下次要確認的事
            """
        case .article: return """
            分享文章：給同事快速讀懂的文章。一段核心主張 → 會議背景 → 想解決的問題 → 依知識架構命名的章節 → 結論 → 一句話帶走。
            圖比文字好懂的地方（關係圖、流程、架構、分層表）引用 slides/ 的截圖，用相對路徑 `![說明](slides/檔名.jpg)`，圖上一行寫「這張圖要看什麼」；一場約 5 到 8 張，切壞或模糊的不要用，slides/index.json 標了「只存整個視窗」的頁面可改用 frames/ 原圖。
            """
        case .custom: return "格式完全照使用者寫的要求；要求沒提到的部分用最精簡的方式處理。"
        }
    }
}

/// 使用者在整理前補充的資訊，帶進規劃與執行兩個階段
struct RunContext {
    var title: String = ""
    var notes: String = ""
    var kind: OutputKind = .summary
    var request: String = ""
    var mcpTools: [String] = []     // 例如 mcp__claude_ai_Notion
    var glossary: String = ""

    /// 從會議資料夾與設定組出來（命令列與預設值用）
    static func load(dir: URL, settings: Settings) -> RunContext {
        let servers = settings.provider == .claude && !settings.allowedMCP.isEmpty
            ? MCPServer.allowedPrefixes(servers: MCPServer.list(claudePath: settings.claudePath), checked: settings.allowedMCP) : []
        return RunContext(title: MeetingFiles.title(dir), notes: MeetingFiles.read(dir, "notes.md"),
                          kind: OutputKind(rawValue: settings.outputKind) ?? .summary,
                          request: MeetingFiles.read(dir, "request.md"), mcpTools: servers, glossary: settings.glossary)
    }

    var promptBlock: String {
        var lines = ["會議名稱：\(title.isEmpty ? "（未填）" : title)"]
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("使用者給的會議說明（理解背景、與會者、專有名詞時以這段為準）：\n\(n.isEmpty ? "（未填）" : n)")
        let g = Glossary(glossary).promptBlock
        if !g.isEmpty { lines.append(g) }
        lines.append("產出類型與格式規則：\n\(kind.rules)")
        let r = request.trimmingCharacters(in: .whitespacesAndNewlines)
        if !r.isEmpty { lines.append("使用者這次的要求（優先於任何預設格式）：\n\(r)") }
        return lines.joined(separator: "\n\n")
    }
}

/// 會議資料夾裡使用者自己寫的東西：notes.md（會議說明）、request.md（上次的整理要求）、meta.json 的標題
enum MeetingFiles {
    static func read(_ dir: URL, _ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
    static func write(_ dir: URL, _ name: String, _ text: String) {
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    static func title(_ dir: URL) -> String {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
        return o["title"] as? String ?? ""
    }
    static func setTitle(_ dir: URL, _ title: String) {
        let url = dir.appendingPathComponent("meta.json")
        guard let d = try? Data(contentsOf: url),
              var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        o["title"] = title
        if let out = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? out.write(to: url)
        }
    }
}

/// 命令列 claude 已設定的 MCP 連線（`claude mcp list`），讓使用者勾選執行時可以用哪些
struct MCPServer: Identifiable, Hashable {
    let name: String
    let connected: Bool
    let status: String
    var id: String { name }
    var usable: Bool { connected }
    /// 服務名稱：「claude.ai Notion」與「plugin:engineering:notion」都是 notion。
    /// 同一個服務常有兩個連線，AI 會挑其中任一個用，所以勾一個就要一起放行（11/9 踩到：只放行 plugin 版，AI 卻呼叫 claude.ai 版被擋）
    var service: String {
        String(name.split(whereSeparator: { $0 == ":" || $0 == " " }).last ?? Substring(name)).lowercased()
    }
    /// 使用者勾的連線，加上同服務的其他已連線連線
    static func allowedPrefixes(servers: [MCPServer], checked: [String]) -> [String] {
        let services = Set(servers.filter { checked.contains($0.name) }.map(\.service))
        var out = servers.filter { $0.usable && (checked.contains($0.name) || services.contains($0.service)) }.map(\.toolPrefix)
        // claude.ai 網頁端的同名連線：網址跟本機那個相同時 `claude mcp list` 會把它藏起來，但執行時仍會載入、AI 也可能挑它用
        for svc in services {
            let web = MCPServer(name: "claude.ai " + svc.prefix(1).uppercased() + svc.dropFirst(), connected: true, status: "").toolPrefix
            if !out.contains(web) { out.append(web) }
        }
        return out
    }
    /// 工具名稱前綴：claude 會把非英數字元換成底線，例如「claude.ai Notion」→ mcp__claude_ai_Notion
    var toolPrefix: String {
        "mcp__" + String(name.map { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }

    static func list(claudePath: String) -> [MCPServer] {
        guard !claudePath.isEmpty else { return [] }
        let r = Shell.run(claudePath, ["mcp", "list"], cwd: FileManager.default.temporaryDirectory, env: Shell.loginEnv)
        var out: [MCPServer] = []
        for raw in r.out.split(separator: "\n") {
            let line = String(raw)
            // 「名稱: 網址或指令 - ✔ Connected」；名稱本身可能含冒號（plugin:engineering:notion），所以用最後的「 - 」切狀態、第一個「: 」之前不可靠，改找「: http」或「: 」後面接網址／指令
            guard let dash = line.range(of: " - ", options: .backwards) else { continue }
            let head = String(line[..<dash.lowerBound]), status = String(line[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard let sep = head.range(of: ": ", options: .backwards) ?? head.range(of: ":", options: .backwards) else { continue }
            let name = String(head[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name.hasPrefix("Checking") { continue }
            out.append(MCPServer(name: name, connected: status.contains("Connected"), status: status))
        }
        return out
    }
}
