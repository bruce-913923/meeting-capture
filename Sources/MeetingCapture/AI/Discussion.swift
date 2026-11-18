import Foundation
import AppKit

/// 「在 Claude Code／Codex 繼續討論」：開一個終端機視窗，切到會議資料夾，啟動 claude 或 codex，
/// 帶一段開場說明（資料夾裡有哪些檔、怎麼讀），之後就像平常一樣對話。
/// 會議中也能用：逐字稿一直在長，開場說明會提醒它回答前重讀最新的即時逐字稿。
enum Discussion {
    /// 開過討論的標記：有它就提供「繼續上次的討論」
    static let marker = ".discussion"

    static func hasPrevious(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(marker).path)
    }

    /// resume＝接回這個資料夾裡最近一次的對話（claude --continue／codex resume --last）
    static func open(dir: URL, settings: Settings, live: Bool, resume: Bool) throws {
        let script = try makeScript(dir: dir, settings: settings, live: live, resume: resume)
        try? settings.provider.rawValue.write(to: dir.appendingPathComponent(marker), atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(script)
    }

    /// 寫出給終端機執行的 .command 腳本（放暫存資料夾，不弄髒會議資料夾）
    static func makeScript(dir: URL, settings: Settings, live: Bool, resume: Bool) throws -> URL {
        let p = settings.provider
        let exe = p == .claude ? settings.claudePath : settings.codexPath
        guard !exe.isEmpty else { throw DiscussionError.noCLI(p == .claude ? "claude" : "codex") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mc-discuss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        var cmd: String
        if resume {
            cmd = p == .claude ? "\(q(exe)) --continue" : "\(q(exe)) resume --last"
        } else {
            let promptFile = tmp.appendingPathComponent("prompt.md")
            try prompt(dir: dir, settings: settings, live: live).write(to: promptFile, atomically: true, encoding: .utf8)
            cmd = "\(q(exe)) \"$(cat \(q(promptFile.path)))\""
        }
        let script = tmp.appendingPathComponent("討論：\(CaptureSession.sanitize(AppState.displayName(dir)).prefix(30)).command")
        try """
        #!/bin/zsh -l
        cd \(q(dir.path)) || exit 1
        \(cmd)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// 單引號包起來給 zsh；內容裡的單引號跳脫
    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func prompt(dir: URL, settings: Settings, live: Bool) -> String {
        let fm = FileManager.default
        func has(_ n: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(n).path) }
        let title = AppState.displayName(dir)
        var files: [String] = []
        if live {
            if has("live-transcript.txt") { files.append("- live-transcript.txt：電腦播出的聲音（線上與會者）的即時逐字稿，會議中每 2 分鐘更新，每行「[時:分:秒] 文字」") }
            if has("live-transcript-mic.txt") { files.append("- live-transcript-mic.txt：現場麥克風的即時逐字稿") }
        }
        if has("transcript.txt") { files.append("- transcript.txt：電腦播出的聲音（線上與會者）的逐字稿，每行「[時:分:秒] 文字」") }
        if has("transcript-mic.txt") { files.append("- transcript-mic.txt：現場麥克風的逐字稿（現場的人、包括使用者自己）") }
        if has("captions.txt") { files.append("- captions.txt：會議軟體畫面上的字幕辨識，可和逐字稿對照") }
        if has("slides") { files.append("- slides/：換頁時截下的簡報圖（slides/index.json 有每頁的時間）") }
        if has("frames") { files.append("- frames/：換頁時整個會議視窗的原圖") }
        if has("notes.md") { files.append("- notes.md：使用者寫的會議說明（背景、與會者、專有名詞），理解內容以它為準") }
        for n in ["summary.md", "minutes.md", "article.md", "output.md"] where has(n) {
            files.append("- \(n)：之前整理好的結果")
        }
        let glossary = Glossary(settings.glossary).promptBlock
        return """
        這個資料夾是會議「\(title)」擷取下來的資料，接下來使用者要跟你討論這場會議的內容。
        \(live ? "\n會議還在進行，逐字稿會持續變長：每次回答前先重讀最新的即時逐字稿，不要只靠一開始讀到的內容。\n" : "")
        資料夾裡有：
        \(files.isEmpty ? "（還沒有逐字稿，先看看資料夾裡有什麼）" : files.joined(separator: "\n"))
        \(glossary.isEmpty ? "" : "\n\(glossary)\n")
        逐字稿是語音辨識的結果，可能有同音錯字；人名、專有名詞以會議說明和常用詞彙為準。
        回答時附上時間點（例如「約 10:32」），讓使用者能回頭對照。圖片等被問到相關內容再看。

        先讀逐字稿和會議說明，用兩三句話說你掌握到的會議主題和目前進度，然後等使用者提問。
        """
    }
}

enum DiscussionError: LocalizedError {
    case noCLI(String)
    var errorDescription: String? {
        switch self {
        case .noCLI(let n): return "找不到 \(n) 指令，請到設定裡指定路徑"
        }
    }
}
