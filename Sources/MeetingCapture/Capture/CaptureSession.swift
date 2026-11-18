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
    /// 線上會議中途打開的現場麥克風：獨立一路錄音，隨時可開關，檔案存 mic/（檔名是開始時刻，所以中間斷掉時間軸也不會錯）
    private var mic: AudioRecorder?
    private let segmentSeconds: Double
    /// 錄音中邊錄邊轉：正式段落與草稿小檔寫完時通知（AppState 排進轉文字）
    private let live: Bool
    var onSegmentClosed: ((URL) -> Void)? { didSet { wire(audio); if let mic { wire(mic) } } }
    var onDraftClosed: ((URL) -> Void)? { didSet { wire(audio); if let mic { wire(mic) } } }

    /// target 為 nil：實體會議，只錄麥克風、不截圖
    init(target: CaptureTarget?, settings: Settings, title: String = "") throws {
        segmentSeconds = settings.segmentSeconds
        live = settings.liveTranscribe && settings.engine.perFile
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (target?.title ?? "實體會議") : title
        let safeTitle = Self.sanitize(name)
        dir = URL(fileURLWithPath: settings.outputRoot).appendingPathComponent("\(f.string(from: Date()))-\(safeTitle)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        meta = Meta(title: name, app: target?.app ?? "（無，現場錄音）",
                    startedAt: ISO8601DateFormatter().string(from: Date()))
        if let target {
            audio = AudioRecorder(dir: dir.appendingPathComponent("audio"), segmentSeconds: settings.segmentSeconds)
            frames = FrameCapture(dir: dir, target: target, interval: settings.captureInterval)
        } else {
            meta.micRecorded = true
            audio = AudioRecorder(dir: dir.appendingPathComponent("mic"), segmentSeconds: settings.segmentSeconds, systemAudio: false)
            frames = nil
        }
        if !live { audio.draftSeconds = 0 }
        writeMeta()
    }

    private func wire(_ r: AudioRecorder) {
        guard live else { return }
        r.onSegmentClosed = onSegmentClosed
        r.onDraftClosed = onDraftClosed
    }

    var onError: ((String) -> Void)? {
        didSet { audio.onError = onError; frames?.onError = onError; mic?.onError = onError }
    }
    var audioPeak: Float { audio.peak }
    var micPeak: Float { mic?.peak ?? 0 }
    var micOn: Bool { mic != nil }

    /// 打開或關掉現場麥克風（只用在線上會議；實體會議本來就只錄麥克風）
    func setMic(_ on: Bool) async throws {
        if on {
            guard mic == nil, frames != nil else { return }
            let m = AudioRecorder(dir: dir.appendingPathComponent("mic"), segmentSeconds: segmentSeconds, systemAudio: false)
            m.onError = onError
            if !live { m.draftSeconds = 0 }
            wire(m)
            try await m.start()
            mic = m
            if !meta.micRecorded { update { $0.micRecorded = true } }
        } else if let m = mic {
            mic = nil
            await m.stop()
        }
    }
    var slideCount: Int { frames?.slideCount ?? 0 }

    func start() async throws {
        try await audio.start()
        frames?.start()
    }

    func stop() async {
        frames?.stop()
        if let m = mic { mic = nil; await m.stop() }
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
