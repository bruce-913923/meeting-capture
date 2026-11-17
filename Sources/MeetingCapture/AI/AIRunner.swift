import Foundation

/// AI 回傳的「要問使用者什麼」。app 只認這幾種題型，只負責畫出來。
struct PlanResponse: Codable {
    struct Option: Codable, Hashable { let value: String; let label: String; let recommended: Bool? }
    struct Question: Codable, Identifiable {
        let id: String
        let type: String            // single / multi / text / confirm
        let label: String
        let help: String?
        let options: [Option]?
        let defaultValue: String?
    }
    let summary: String             // 一句話說明 AI 看到的會議
    let questions: [Question]
}

struct ExecuteResponse: Codable {
    struct Correction: Codable, Hashable { let wrong: String; let right: String; let kind: String }
    let status: String              // ok / failed
    let summary: String
    let url: String?
    let outputPath: String?
    /// AI 整理時判斷逐字稿聽錯的詞，讓使用者勾選加進常用詞彙
    let corrections: [Correction]?
}

enum AIError: LocalizedError {
    case notConfigured(String), failed(String), badJSON(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return s
        case .failed(let s): return "AI 執行失敗：\(s)"
        case .badJSON(let s): return "AI 回傳的格式不對：\(s)"
        }
    }
}

enum AIRunner {
    static func plan(dir: URL, skill: SkillInfo, context: RunContext, settings: Settings) async throws -> PlanResponse {
        let prompt = """
        你是「會議擷取 app」的大腦。會議資料夾在：\(dir.path)
        裡面有 meta.json（標題、時間）、notes.md（使用者寫的會議說明，有的話）、transcript.txt（電腦播出聲音的語音轉文字，主要來源）、transcript-mic.txt（有的話：會議室現場麥克風的轉文字，現場的人說的話在這裡）、captions.txt（會議軟體字幕 OCR，品質較差，可對照講者姓名）、slides/（換頁時切出的簡報圖，slides/index.json 有對照）、frames/（整個視窗原圖）。

        使用者選的整理方式：\(skillLine(skill, context))

        \(context.promptBlock)

        這一步只做規劃，不要寫任何檔案、不要上傳任何東西。請先看 meta.json 與 transcript.txt 開頭，判斷這是什麼會議，再依整理方式決定執行前需要使用者確認哪些事（例如要放到哪個資料庫或分類、頁面標題、會議類型），每題附上你推薦的選項。題目越少越好，最多 4 題；能自己判斷的、使用者在上面已經寫清楚的就不要問。產出類型使用者已經選好，不要再問。
        只回傳符合 JSON schema 的物件。type 只能是 single、multi、text、confirm；single 與 multi 必須給 options，並把推薦的那個 recommended 設為 true；text 用 defaultValue 給預設值。
        """
        let data = try await run(prompt: prompt, schema: planSchema, dir: dir, skill: skill, context: context, writeAccess: false, settings: settings)
        do { return try JSONDecoder().decode(PlanResponse.self, from: data) }
        catch { throw AIError.badJSON(String(data: data, encoding: .utf8)?.prefix(400).description ?? "") }
    }

    static func execute(dir: URL, skill: SkillInfo, answers: [String: String], context: RunContext, settings: Settings) async throws -> ExecuteResponse {
        let answerText = answers.map { "- \($0.key)：\($0.value)" }.sorted().joined(separator: "\n")
        let prompt = """
        你是「會議擷取 app」的大腦。會議資料夾在：\(dir.path)（說明同規劃階段：meta.json、notes.md、transcript.txt、transcript-mic.txt、captions.txt、slides/、frames/）。

        整理方式：\(skillLine(skill, context))

        \(context.promptBlock)

        使用者已確認：
        \(answerText)

        請依整理方式把這場會議整理好並輸出。不論最後放到哪裡，都在會議資料夾另存一份 \(context.kind.fileName)。如果某個需要的工具被擋下或沒授權，status 回 failed，summary 寫清楚是哪個工具。完成後只回傳符合 JSON schema 的物件：status 為 ok 或 failed，summary 用一兩句繁體中文說明做了什麼，有頁面網址就放 url，有本機檔案就放 outputPath。
        corrections：列出你判斷逐字稿聽錯、整理時改掉的人名、專案名、專業用語，讓使用者加進常用詞彙。wrong 是逐字稿裡的原文（一字不差，之後會拿來直接替換），right 是正確寫法，kind 是「人名」「專有名詞」「用語」其中之一。只列有把握、而且之後還可能再出現的；wrong 如果是常見詞（例如「後段」「投票」「體育」）就不要列，免得替換時誤傷；常用詞彙裡已經有的對照不用再列。沒有就給空陣列。
        """
        let data = try await run(prompt: prompt, schema: executeSchema, dir: dir, skill: skill, context: context, writeAccess: true, settings: settings)
        do { return try JSONDecoder().decode(ExecuteResponse.self, from: data) }
        catch { throw AIError.badJSON(String(data: data, encoding: .utf8)?.prefix(400).description ?? "") }
    }

    private static func skillLine(_ skill: SkillInfo, _ context: RunContext) -> String {
        if skill.id == "builtin" {
            return "內建整理規則（附在系統提示裡），只輸出到會議資料夾的 \(context.kind.fileName)，不上傳。"
        }
        return "使用 skill「\(skill.name)」（\(skill.id)）。請先讀這份 SKILL.md 與它引用的檔案：要放到哪裡、怎麼上傳照 skill；內容的格式與篇幅以下面的產出類型和使用者要求為準，跟 skill 預設樣板衝突時以使用者為準。"
    }

    private static func run(prompt: String, schema: String, dir: URL, skill: SkillInfo, context: RunContext, writeAccess: Bool, settings: Settings) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            switch settings.provider {
            case .claude: return try runClaude(prompt: prompt, schema: schema, dir: dir, skill: skill, context: context, writeAccess: writeAccess, settings: settings)
            case .codex: return try runCodex(prompt: prompt, schema: schema, dir: dir, skill: skill, writeAccess: writeAccess, settings: settings)
            }
        }.value
    }

    private static func runClaude(prompt: String, schema: String, dir: URL, skill: SkillInfo, context: RunContext, writeAccess: Bool, settings: Settings) throws -> Data {
        guard !settings.claudePath.isEmpty else { throw AIError.notConfigured("找不到 claude 指令，請在設定裡指定路徑") }
        var tools = ["Read", "Glob", "Grep", "Skill"]
        // MCP 工具在背景模式是延後載入，要 ToolSearch 才叫得到
        if writeAccess { tools += ["Write", "Edit", "Bash", "ToolSearch"] + context.mcpTools + settings.claudeExtraTools.split(separator: " ").map(String.init) }
        var args = ["-p", prompt, "--output-format", "json", "--json-schema", schema,
                    "--allowedTools", tools.joined(separator: ","), "--add-dir", dir.path]
        if !settings.claudeModel.isEmpty { args += ["--model", settings.claudeModel] }
        if skill.id == "builtin" {
            args += ["--append-system-prompt-file", Resources.write(name: "default-skill.md", content: Prompts.defaultSkill).path]
        } else {
            args += ["--add-dir", URL(fileURLWithPath: skill.id).deletingLastPathComponent().path]
        }
        let r = Shell.run(settings.claudePath, args, cwd: dir, env: Shell.loginEnv)
        guard r.code == 0 else { throw AIError.failed("exit \(r.code)\n" + String((r.err + "\n" + r.out).suffix(1200))) }
        // --output-format json 的外層：{ "result": "...", "structured_output": {...}, "is_error": false, ... }
        guard let outer = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any] else {
            throw AIError.badJSON(String(r.out.prefix(400)))
        }
        if (outer["is_error"] as? Bool) == true { throw AIError.failed(outer["result"] as? String ?? r.out) }
        let denied = Set(((outer["permission_denials"] as? [[String: Any]]) ?? []).compactMap { $0["tool_name"] as? String }).sorted()
        if var s = outer["structured_output"] as? [String: Any] {
            if !denied.isEmpty, let sum = s["summary"] as? String {
                s["summary"] = sum + "\n\n被擋下的工具：" + denied.joined(separator: "、")
            }
            if let d = try? JSONSerialization.data(withJSONObject: s) { return d }
        }
        if let text = outer["result"] as? String, let d = extractJSON(text) { return d }
        throw AIError.badJSON(String(r.out.prefix(400)))
    }

    private static func runCodex(prompt: String, schema: String, dir: URL, skill: SkillInfo, writeAccess: Bool, settings: Settings) throws -> Data {
        guard !settings.codexPath.isEmpty else { throw AIError.notConfigured("找不到 codex 指令，請在設定裡指定路徑") }
        let schemaURL = Resources.write(name: "schema-\(UUID().uuidString).json", content: schema)
        let lastURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-last-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: schemaURL) }
        var fullPrompt = prompt
        if skill.id == "builtin" { fullPrompt = Prompts.defaultSkill + "\n\n" + prompt }
        var args = ["exec", "--skip-git-repo-check", "-C", dir.path]
        if !settings.codexModel.isEmpty { args += ["-m", settings.codexModel] }
        args += [
                    "--sandbox", writeAccess ? "workspace-write" : "read-only",
                    "--output-schema", schemaURL.path, "-o", lastURL.path, fullPrompt]
        let r = Shell.run(settings.codexPath, args, cwd: dir, env: Shell.loginEnv)
        guard r.code == 0 else { throw AIError.failed("exit \(r.code)\n" + String((r.err + "\n" + r.out).suffix(1200))) }
        guard let text = try? String(contentsOf: lastURL, encoding: .utf8), let d = extractJSON(text) else {
            throw AIError.badJSON(String(r.out.suffix(400)))
        }
        return d
    }

    /// 從文字裡挖出第一個完整的 JSON 物件
    static func extractJSON(_ text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let d = Data(text[start...end].utf8)
        return (try? JSONSerialization.jsonObject(with: d)) != nil ? d : nil
    }

    static let planSchema = #"""
    {"type":"object","additionalProperties":false,"required":["summary","questions"],
     "properties":{
      "summary":{"type":"string"},
      "questions":{"type":"array","maxItems":4,"items":{"type":"object","additionalProperties":false,
        "required":["id","type","label","help","options","defaultValue"],
        "properties":{
          "id":{"type":"string"},
          "type":{"type":"string","enum":["single","multi","text","confirm"]},
          "label":{"type":"string"},
          "help":{"type":["string","null"]},
          "defaultValue":{"type":["string","null"]},
          "options":{"type":["array","null"],"items":{"type":"object","additionalProperties":false,
            "required":["value","label","recommended"],
            "properties":{"value":{"type":"string"},"label":{"type":"string"},"recommended":{"type":["boolean","null"]}}}}
        }}}
     }}
    """#

    static let executeSchema = #"""
    {"type":"object","additionalProperties":false,"required":["status","summary","url","outputPath","corrections"],
     "properties":{
      "status":{"type":"string","enum":["ok","failed"]},
      "summary":{"type":"string"},
      "url":{"type":["string","null"]},
      "outputPath":{"type":["string","null"]},
      "corrections":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["wrong","right","kind"],
        "properties":{"wrong":{"type":"string"},"right":{"type":"string"},"kind":{"type":"string"}}}}
     }}
    """#
}

enum Prompts {
    /// 內建整理的共通規則；格式由產出類型（OutputKind.rules）決定
    static let defaultSkill = """
    # 內建會議整理規則

    把會議整理成繁體中文 Markdown，存在會議資料夾，檔名與格式依使用者選的產出類型。

    - 先吸收內容再寫，不要逐頁搬簡報、不要放逐字稿。
    - 使用者寫的會議說明（notes.md）是理解背景的依據：與會者、專案名稱、專有名詞以它為準。
    - 語音轉文字有錯字，專有名詞以簡報文字與會議說明為準；聽不清楚的地方寫「（錄音不清）」，不要猜成肯定句。
    - 自己的推論標「整理者解讀」。
    - 用人話寫：完整句子、少術語、不要用斜線或箭頭串接縮寫。
    - 最後一行註明素材來源與缺漏（例如哪段沒錄到）。
    """
}
