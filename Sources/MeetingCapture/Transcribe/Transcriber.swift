import Foundation
import Speech

/// 轉文字：依設定的引擎把 audio/*.m4a 轉成 transcript.txt（每行「[時:分:秒] 文字」）。
enum Transcriber {
    /// 兩路聲音：audio/＝電腦播出的聲音（遠端與會者）；mic/＝現場麥克風
    static let sources = [("audio", "transcript.txt"), ("mic", "transcript-mic.txt")]

    /// 整場轉文字。MLX／faster-whisper 逐檔轉、每檔結果存在旁邊的 .txt：錄音中已轉好的段落不重轉。
    /// fresh＝重新轉文字（換引擎或改常用詞彙後），先清掉逐檔結果
    static func transcribe(dir: URL, settings: Settings, fresh: Bool = false) async throws {
        for (sub, outName) in sources {
            let audioDir = dir.appendingPathComponent(sub)
            guard FileManager.default.fileExists(atPath: audioDir.path) else { continue }
            let out = dir.appendingPathComponent(outName)
            if settings.engine.perFile {
                if fresh { clearCaches(audioDir) }
                let todo = uncached(audioDir)
                if !todo.isEmpty { try transcribeFiles(todo, settings: settings) }
                try assemble(audioDir: audioDir, out: out)
            } else {
                try await transcribeFolder(audioDir: audioDir, out: out, settings: settings)
            }
            GlossaryStats.record(Glossary(settings.glossary).fix(file: out), dir: dir)
        }
    }

    // MARK: 逐檔

    static func segments(_ audioDir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static func cache(_ file: URL) -> URL { file.deletingPathExtension().appendingPathExtension("txt") }
    static func uncached(_ audioDir: URL) -> [URL] {
        segments(audioDir).filter { !FileManager.default.fileExists(atPath: cache($0).path) }
    }
    static func clearCaches(_ audioDir: URL) {
        for f in segments(audioDir) { try? FileManager.default.removeItem(at: cache(f)) }
    }

    /// 一次轉多個檔（只載入一次模型），每檔寫出旁邊的 .txt
    static func transcribeFiles(_ files: [URL], settings: Settings) throws {
        let r = runPython(settings: settings, args: ["--files"] + files.map(\.path))
        guard r.code == 0 else { throw TranscribeError.failed(r.err.suffix(800).description) }
    }

    /// 把逐檔結果依時間接成一份逐字稿
    static func assemble(audioDir: URL, out: URL) throws {
        let text = segments(audioDir).compactMap { try? String(contentsOf: cache($0), encoding: .utf8) }.joined()
        try text.write(to: out, atomically: true, encoding: .utf8)
    }

    /// 會議中轉一個檔（正式段落或草稿），轉完更新即時逐字稿。失敗回傳 false（結束後整場收尾會再轉）
    static func runLive(file: URL, dir: URL, settings: Settings) async -> Bool {
        guard settings.engine.perFile else { return false }
        let ok = FileManager.default.fileExists(atPath: cache(file).path)
            || (try? transcribeFiles([file], settings: settings)) != nil
        assembleLive(dir: dir, settings: settings)
        return ok
    }

    /// 整場收尾前還沒轉的檔（逐檔引擎才有）；fresh 時先清掉舊結果
    static func pending(dir: URL, settings: Settings, fresh: Bool) async -> [URL] {
        guard settings.engine.perFile else { return [] }
        return sources.flatMap { (sub, _) -> [URL] in
            let audioDir = dir.appendingPathComponent(sub)
            guard FileManager.default.fileExists(atPath: audioDir.path) else { return [] }
            if fresh { clearCaches(audioDir) }
            return uncached(audioDir)
        }
    }

    // MARK: 會議中的即時逐字稿

    static let liveNames = ["audio": "live-transcript.txt", "mic": "live-transcript-mic.txt"]

    /// 即時逐字稿＝已轉好的正式段落＋之後的草稿。
    /// 相鄰草稿重疊幾秒：前一份只取「下一份開始之前」開頭的句子、下一份取它自己開始之後的。
    /// 模型給的句子時間只標開頭（常是 0 秒），用中點切會整句丟掉；這樣切頂多重複半句，不會漏
    static func assembleLive(dir: URL, settings: Settings) {
        for (sub, _) in sources {
            let audioDir = dir.appendingPathComponent(sub)
            guard FileManager.default.fileExists(atPath: audioDir.path), let name = liveNames[sub] else { continue }
            let segs = segments(audioDir)
            var text = ""
            var cutoff = Int.max
            for f in segs {
                if let t = try? String(contentsOf: cache(f), encoding: .utf8) { text += t }
                else { cutoff = Clock.from(fileName: f.lastPathComponent); break }
            }
            let drafts = segments(dir.appendingPathComponent("live").appendingPathComponent(sub))
                .filter { FileManager.default.fileExists(atPath: cache($0).path) }
            for (i, d) in drafts.enumerated() {
                let lo = i == 0 ? 0 : Clock.from(fileName: d.lastPathComponent)
                let hi = i + 1 < drafts.count ? Clock.from(fileName: drafts[i + 1].lastPathComponent) : Int.max
                for line in ((try? String(contentsOf: cache(d), encoding: .utf8)) ?? "").split(separator: "\n") {
                    guard let t = Clock.parse(line), t >= cutoff, t >= lo, t < hi else { continue }
                    text += line + "\n"
                }
            }
            let out = dir.appendingPathComponent(name)
            try? text.write(to: out, atomically: true, encoding: .utf8)
            Glossary(settings.glossary).fix(file: out)
        }
    }

    /// 會議結束、正式逐字稿好了以後，草稿與即時逐字稿就用不到了
    static func clearLive(dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("live"))
        for n in liveNames.values { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    }

    static func transcribeFolder(audioDir: URL, out: URL, settings: Settings) async throws {
        switch settings.engine {
        case .apple:
            try await AppleSpeech.transcribe(audioDir: audioDir, out: out, language: settings.language)
        case .mlx, .fasterWhisper:
            let r = runPython(settings: settings, args: ["--audio-dir", audioDir.path, "--out", out.path])
            guard r.code == 0 else { throw TranscribeError.failed(r.err.suffix(800).description) }
        case .custom:
            try runCustom(audioDir: audioDir, out: out, settings: settings)
        }
    }

    /// 自訂指令：每段音檔跑一次，輸出的純文字依段落開始時間標上時鐘
    static func runCustom(audioDir: URL, out: URL, settings: Settings) throws {
        guard settings.customCommand.contains("{audio}") else { throw TranscribeError.failed("自訂指令裡要有 {audio}") }
        let files = (try FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines: [String] = []
        for f in files {
            // 多數工具只吃 wav，先轉成 16kHz 單聲道
            let wav = f.deletingPathExtension().appendingPathExtension("wav")
            let ff = Shell.which("ffmpeg") ?? "/opt/homebrew/bin/ffmpeg"
            Shell.run(ff, ["-v", "error", "-y", "-i", f.path, "-ar", "16000", "-ac", "1", wav.path])
            let txtBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let cmd = settings.customCommand
                .replacingOccurrences(of: "{audio}", with: "'\(wav.path)'")
                .replacingOccurrences(of: "{model}", with: "'\(settings.modelPath)'")
                .replacingOccurrences(of: "{out}", with: "'\(txtBase.path)'")
            let r = Shell.run("/bin/zsh", ["-lc", cmd], env: Shell.loginEnv)
            try? FileManager.default.removeItem(at: wav)
            guard r.code == 0 else { throw TranscribeError.failed(String(r.err.suffix(600))) }
            let text = (try? String(contentsOf: txtBase.appendingPathExtension("txt"), encoding: .utf8))
                ?? (try? String(contentsOf: txtBase, encoding: .utf8)) ?? r.out
            let base = Clock.from(fileName: f.lastPathComponent)
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("[\(Clock.add(base, 0))] \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    /// 存設定前試跑：用系統內建的 say 產生一段中文測試音檔
    static func test(settings: Settings) async -> (ok: Bool, message: String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mc-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let wav = tmp.appendingPathComponent("120000.m4a")
        let say = Shell.run("/usr/bin/say", ["-v", "Meijia", "-o", wav.path, "--data-format=aac", "這是一段語音辨識的測試，今天天氣很好。"])
        guard say.code == 0 else { return (false, "產生測試音檔失敗：\(say.err)") }
        let out = tmp.appendingPathComponent("t.txt")
        do {
            switch settings.engine {
            case .apple:
                try await AppleSpeech.transcribe(audioDir: tmp, out: out, language: settings.language)
            case .mlx, .fasterWhisper:
                let r = runPython(settings: settings, args: ["--audio-dir", tmp.path, "--out", out.path])
                guard r.code == 0 else { return (false, String(r.err.suffix(600))) }
            case .custom:
                try runCustom(audioDir: tmp, out: out, settings: settings)
            }
            let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            return text.isEmpty ? (false, "沒有辨識出文字") : (true, text)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    static func runPython(settings: Settings, args: [String]) -> (code: Int32, out: String, err: String) {
        let script = Resources.write(name: "transcribe.py", content: Resources.transcribePy)
        let py = settings.pythonPath.isEmpty ? "/usr/bin/python3" : settings.pythonPath
        let modelDir = URL(fileURLWithPath: settings.modelPath).deletingLastPathComponent()
        var env = Shell.loginEnv
        env["PYTHONNOUSERSITE"] = "1"
        let hint = Glossary(settings.glossary).asrHint(root: settings.outputRoot)
        return Shell.run(py, ["-I", script.path, "--engine", settings.engine.rawValue,
                              "--model", settings.modelPath, "--language", settings.language,
                              "--hint", hint] + args,
                         cwd: modelDir, env: env)
    }
}

enum TranscribeError: LocalizedError {
    case failed(String), notAuthorized, unavailable
    var errorDescription: String? {
        switch self {
        case .failed(let s): return "轉文字失敗：\(s)"
        case .notAuthorized: return "沒有語音辨識權限（系統設定 › 隱私權與安全性 › 語音辨識）"
        case .unavailable: return "這台電腦的內建語音辨識不支援這個語言"
        }
    }
}

enum AppleSpeech {
    static func transcribe(audioDir: URL, out: URL, language: String) async throws {
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { throw TranscribeError.notAuthorized }
        let locale = Locale(identifier: language.hasPrefix("zh") ? "zh-TW" : language)
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else { throw TranscribeError.unavailable }
        let files = (try FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines: [String] = []
        for f in files {
            let base = Clock.from(fileName: f.lastPathComponent)
            let req = SFSpeechURLRecognitionRequest(url: f)
            req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
            req.shouldReportPartialResults = false
            let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { c in
                var done = false
                rec.recognitionTask(with: req) { r, e in
                    guard !done else { return }
                    if let e { done = true; c.resume(throwing: e) }
                    else if let r, r.isFinal { done = true; c.resume(returning: r) }
                }
            }
            // 依停頓切句：兩個字之間隔超過 1 秒就換行
            var cur = "", curStart: TimeInterval = 0, lastEnd: TimeInterval = 0
            for seg in result.bestTranscription.segments {
                if !cur.isEmpty && seg.timestamp - lastEnd > 1.0 {
                    lines.append("[\(Clock.add(base, curStart))] \(cur)"); cur = ""
                }
                if cur.isEmpty { curStart = seg.timestamp }
                cur += seg.substring; lastEnd = seg.timestamp + seg.duration
            }
            if !cur.isEmpty { lines.append("[\(Clock.add(base, curStart))] \(cur)") }
        }
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }
}

enum Clock {
    /// 檔名「HHmmss.m4a」→ 當天秒數
    static func from(fileName: String) -> Int {
        let s = fileName.prefix(6)
        guard s.count == 6, let h = Int(s.prefix(2)), let m = Int(s.dropFirst(2).prefix(2)), let sec = Int(s.suffix(2)) else { return 0 }
        return h * 3600 + m * 60 + sec
    }
    /// 逐字稿一行「[HH:MM:SS] 文字」→ 當天秒數
    static func parse<S: StringProtocol>(_ line: S) -> Int? {
        guard line.hasPrefix("["), line.count >= 10 else { return nil }
        return from(fileName: line.dropFirst().prefix(8).replacingOccurrences(of: ":", with: ""))
    }
    static func add(_ base: Int, _ offset: TimeInterval) -> String {
        let t = base + Int(offset)
        return String(format: "%02d:%02d:%02d", (t / 3600) % 24, (t / 60) % 60, t % 60)
    }
}
