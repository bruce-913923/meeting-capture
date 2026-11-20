import Foundation

/// 常用詞彙（人名、專案名、專有名詞）。設定裡一行一個；常被聽錯的寫成「錯字1、錯字2 > 正確」（由左到右）。
/// 錯字可以含空白（「human inner loop」是一個錯字，不會拆成三個）。
/// 用在三個地方：轉文字時當提示詞、轉完把錯字換掉、AI 整理時當專有名詞依據。
/// `#` 開頭是分類標題；標題含「人名」或「固定」的那一區，提示時固定排最前面。
struct Glossary {
    var terms: [String] = []
    var pinned: [String] = []
    var fixes: [(wrong: String, right: String)] = []

    init(_ text: String) {
        var inPinned = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { inPinned = Self.isPinnedHeading(line); continue }
            let (wrongs, right) = Self.parse(line)
            guard !right.isEmpty else { continue }
            if !terms.contains(right) { terms.append(right) }
            if inPinned && !pinned.contains(right) { pinned.append(right) }
            for w in wrongs { fixes.append((w, right)) }
        }
        // 長的錯字先換，避免短的先換掉一半
        fixes.sort { $0.wrong.count > $1.wrong.count }
    }

    static func isPinnedHeading(_ line: String) -> Bool { line.contains("人名") || line.contains("固定") }

    /// 一行拆成（錯字們, 正確）。箭頭可寫 >、->、=>、→；反方向「正確 <- 錯字」也接受；沒有箭頭＝只列常用詞。
    /// 錯字之間用頓號、逗號或分號分開；空白不算分隔（以前算，「麥肯 c」被拆出一個「c」，把逐字稿裡英文的 c 全換掉）
    static func parse(_ line: String) -> ([String], String) {
        var norm = line
        for back in ["<-", "←"] {
            let p = norm.components(separatedBy: back)
            if p.count == 2 { norm = p[1] + ">" + p[0] }
        }
        for arrow in ["->", "=>", "→", ">"] { norm = norm.replacingOccurrences(of: arrow, with: "\u{1}") }
        let parts = norm.components(separatedBy: "\u{1}")
        let right = parts[parts.count - 1].trimmingCharacters(in: .whitespaces)
        var wrongs: [String] = []
        for w in parts.dropLast().joined(separator: "、").split(whereSeparator: { "、,，;；".contains($0) }) {
            let w = w.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            // 只有符號的不算錯字，免得把逐字稿裡的「-」都換掉
            guard w.contains(where: { $0.isLetter || $0.isNumber }), w != right, !wrongs.contains(w) else { continue }
            wrongs.append(w)
        }
        return (wrongs, right)
    }

    var isEmpty: Bool { terms.isEmpty }

    func knows(wrong: String, right: String) -> Bool { fixes.contains { $0.wrong == wrong && $0.right == right } }

    // MARK: 給語音模型的提示

    /// Whisper 的提示上限約 220 個 token，超過會從「前面」被截掉；中文一字約 1～2 個 token，所以取到約 120 字
    static let asrHintChars = 120

    /// 固定區（人名）照表上順序排最前面；其他詞依最近幾場的分數（被替換次數×3＋出現次數）排，空間用完為止
    func asrHint(root: String?) -> String {
        let score = root.map { GlossaryStats.scores(terms: terms, root: $0) } ?? [:]
        let rest = terms.filter { !pinned.contains($0) }
            .enumerated().sorted { a, b in
                let sa = score[a.element] ?? 0, sb = score[b.element] ?? 0
                return sa != sb ? sa > sb : a.offset < b.offset
            }.map(\.element)
        var out: [String] = [], n = 0
        for t in pinned + rest {
            if n + t.count + 1 > Self.asrHintChars { continue }   // 放不下就跳過，換短的試試
            out.append(t); n += t.count + 1
        }
        return out.joined(separator: "、")
    }

    // MARK: 給 AI

    var promptBlock: String {
        guard !terms.isEmpty else { return "" }
        var s = "常用詞彙（人名、專案名、專有名詞；逐字稿出現同音或近音字時以這裡為準）：\n" + terms.joined(separator: "、")
        if !fixes.isEmpty { s += "\n已知的聽錯對照：" + fixes.map { "\($0.wrong)→\($0.right)" }.joined(separator: "、") }
        return s
    }

    // MARK: 轉文字後的錯字替換

    /// 回傳每個正確詞被換了幾處
    @discardableResult
    func fix(file: URL) -> [String: Int] {
        guard !fixes.isEmpty, let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        let (out, counts) = apply(text)
        if !counts.isEmpty { try? out.write(to: file, atomically: true, encoding: .utf8) }
        return counts
    }

    /// 錯字怎麼比：中間的空白有幾個都算（「麥肯 c」也比得到「麥肯c」）；英文不分大小寫；
    /// 開頭或結尾是英數字時只比完整的詞，「c」不會比到 sync、cover 裡面
    static func pattern(_ wrong: String) -> NSRegularExpression? {
        let words = wrong.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        let isWordChar: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
        var p = words.joined(separator: "\\s*")
        if let c = wrong.first, isWordChar(c) { p = "(?<![A-Za-z0-9])" + p }
        if let c = wrong.last, isWordChar(c) { p += "(?![A-Za-z0-9])" }
        return try? NSRegularExpression(pattern: p, options: .caseInsensitive)
    }

    /// 把錯字換成正確詞，回傳（新文字, 每個正確詞換了幾處）。
    /// 先在原文找完所有位置再一起換：長的錯字先佔位置，換上去的字不會再被別條換到；
    /// 原本就是正確寫法的地方不動（「麥肯」不會把「麥肯錫」換成「麥肯錫錫」）
    func apply(_ text: String) -> (String, [String: Int]) {
        let ns = text as NSString
        var taken: [NSRange] = []
        for right in Set(fixes.map { $0.right }) where !right.isEmpty {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: right, options: [], range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                taken.append(r)
                from = r.location + r.length
            }
        }
        var hits: [(range: NSRange, right: String)] = []
        for f in fixes {
            guard let re = Self.pattern(f.wrong) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                let r = m.range
                if ns.substring(with: r) == f.right || taken.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
                taken.append(r)
                hits.append((r, f.right))
            }
        }
        guard !hits.isEmpty else { return (text, [:]) }
        let out = NSMutableString(string: text)
        var counts: [String: Int] = [:]
        for h in hits.sorted(by: { $0.range.location > $1.range.location }) {
            out.replaceCharacters(in: h.range, with: h.right)
            counts[h.right, default: 0] += 1
        }
        return (out as String, counts)
    }

    // MARK: 把 AI 回報的修正加進詞彙表文字

    /// 已有同一個正確詞的那行就把錯字補到左邊；沒有就新增一行。人名放進「人名」區的最後，其他放到最後面
    static func adding(_ text: String, wrong: String, right: String, kind: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("#") && !t.isEmpty && parse(t).1 == right
        }) {
            let (wrongs, _) = parse(lines[i].trimmingCharacters(in: .whitespaces))
            if wrongs.contains(wrong) { return text }
            lines[i] = (wrongs + [wrong]).joined(separator: "、") + " > " + right
            return lines.joined(separator: "\n")
        }
        let newLine = "\(wrong) > \(right)"
        if kind == "人名", let h = lines.firstIndex(where: { $0.hasPrefix("#") && isPinnedHeading($0) }) {
            var end = h + 1
            while end < lines.count, !lines[end].hasPrefix("#") { end += 1 }
            // 區塊尾端的空行留在後面
            var at = end
            while at > h + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert(newLine, at: at)
            return lines.joined(separator: "\n")
        }
        var s = text
        if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
        return s + newLine
    }
}

/// 最近幾場會議裡，每個常用詞出現與被替換的次數（決定提示要放哪些詞）
enum GlossaryStats {
    static let recentMeetings = 5
    static let fixesFile = "glossary-fixes.json"

    static func record(_ counts: [String: Int], dir: URL) {
        guard !counts.isEmpty else { return }
        let url = dir.appendingPathComponent(fixesFile)
        var old = (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: url))) ?? [:]
        for (k, v) in counts { old[k, default: 0] += v }
        if let d = try? JSONEncoder().encode(old) { try? d.write(to: url) }
    }

    static func scores(terms: [String], root: String) -> [String: Int] {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("transcript.txt").path) || fm.fileExists(atPath: $0.appendingPathComponent("transcript-mic.txt").path) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }.prefix(recentMeetings)
        var score: [String: Int] = [:]
        for d in dirs {
            let text = ["transcript.txt", "transcript-mic.txt"]
                .compactMap { try? String(contentsOf: d.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
            for t in terms { score[t, default: 0] += text.components(separatedBy: t).count - 1 }
            if let data = try? Data(contentsOf: d.appendingPathComponent(fixesFile)),
               let f = try? JSONDecoder().decode([String: Int].self, from: data) {
                for (k, v) in f { score[k, default: 0] += v * 3 }
            }
        }
        return score
    }
}
