import Foundation

/// 一場會議的擷取：錄音＋截圖＋字幕，寫進同一個資料夾。
final class CaptureSession {
    struct Meta: Codable {
        var title: String
        var app: String
        var startedAt: String
        var endedAt: String?
        var slideCount: Int = 0
        var engine: String?
        var transcriptReady: Bool = false
        var micRecorded: Bool = false
    }

    let dir: URL
    private(set) var meta: Meta
    private let audio: AudioRecorder
    private let frames: FrameCapture?

    /// target 為 nil：實體會議，只錄麥克風、不截圖
    init(target: CaptureTarget?, settings: Settings, includeMic: Bool = false, title: String = "") throws {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (target?.title ?? "實體會議") : title
        let safeTitle = Self.sanitize(name)
        dir = URL(fileURLWithPath: settings.outputRoot).appendingPathComponent("\(f.string(from: Date()))-\(safeTitle)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        meta = Meta(title: name, app: target?.app ?? "（無，現場錄音）",
                    startedAt: ISO8601DateFormatter().string(from: Date()))
        if let target {
            meta.micRecorded = includeMic
            audio = AudioRecorder(dir: dir.appendingPathComponent("audio"), segmentSeconds: settings.segmentSeconds, includeMic: includeMic)
            frames = FrameCapture(dir: dir, target: target, interval: settings.captureInterval)
        } else {
            meta.micRecorded = true
            audio = AudioRecorder(dir: dir.appendingPathComponent("mic"), segmentSeconds: settings.segmentSeconds, systemAudio: false)
            frames = nil
        }
        writeMeta()
    }

    var onError: ((String) -> Void)? {
        didSet { audio.onError = onError; frames?.onError = onError }
    }
    var audioPeak: Float { audio.peak }
    var slideCount: Int { frames?.slideCount ?? 0 }

    func start() async throws {
        try await audio.start()
        frames?.start()
    }

    func stop() async {
        frames?.stop()
        await audio.stop()
        meta.endedAt = ISO8601DateFormatter().string(from: Date())
        meta.slideCount = frames?.slideCount ?? 0
        writeMeta()
    }

    func update(_ change: (inout Meta) -> Void) { change(&meta); writeMeta() }

    private func writeMeta() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? enc.encode(meta).write(to: dir.appendingPathComponent("meta.json"))
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n")
        let cleaned = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "meeting" : cleaned).prefix(60))
    }
}
