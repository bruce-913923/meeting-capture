import Foundation

struct SkillInfo: Identifiable, Hashable {
    let id: String          // SKILL.md 路徑；內建的是 "builtin"
    let name: String
    let description: String
    let source: String      // Claude / Codex / 共用 / 內建
}

/// 掃各工具放 skill 的資料夾，讀 SKILL.md 開頭的 name 與 description。
enum SkillScanner {
    static let builtin = SkillInfo(id: "builtin", name: "預設會議文章（內建）",
                                   description: "寫成精簡文章存在會議資料夾的 article.md，關鍵處引用簡報圖，不放逐字稿",
                                   source: "內建")

    static func scan(provider: Provider, extraDirs: [String]) -> [SkillInfo] {
        let home = NSHomeDirectory()
        var roots: [(String, String)] = []
        switch provider {
        case .claude: roots.append((home + "/.claude/skills", "Claude"))
        case .codex: roots.append((home + "/.codex/skills", "Codex"))
        }
        roots.append((home + "/.agents/skills", "共用"))
        roots += extraDirs.map { ($0, "自訂") }

        var found: [SkillInfo] = [builtin]
        var seen = Set<String>()
        for (root, source) in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for item in items.sorted() {
                let path = (root as NSString).appendingPathComponent(item) + "/SKILL.md"
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                      let fm = frontmatter(text), let name = fm["name"], !seen.contains(name) else { continue }
                seen.insert(name)
                found.append(SkillInfo(id: path, name: name, description: fm["description"] ?? "", source: source))
            }
        }
        return found
    }

    /// 只讀簡單的 key: value（description 可能是多行 >- 或引號字串）
    static func frontmatter(_ text: String) -> [String: String]? {
        guard text.hasPrefix("---") else { return nil }
        let body = text.dropFirst(3)
        guard let end = body.range(of: "\n---") else { return nil }
        var out: [String: String] = [:]
        var currentKey: String?
        for raw in body[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let c = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = String(line[..<c]).trimmingCharacters(in: .whitespaces)
                var val = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                if val == ">-" || val == ">" || val == "|" { val = "" }
                val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                out[key] = val; currentKey = key
            } else if let k = currentKey {
                out[k] = ((out[k] ?? "") + " " + line.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    /// 是否跟會議整理有關（選單只列這些，其餘收在「其他」）
    static func isMeetingRelated(_ s: SkillInfo) -> Bool {
        let keys = ["會議", "筆記", "紀錄", "meeting", "notes", "minutes", "notion", "transcript"]
        let t = (s.name + " " + s.description).lowercased()
        return s.id == "builtin" || keys.contains { t.contains($0) }
    }
}
