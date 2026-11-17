import Foundation
import AVFoundation

/// 匯入會議錄影或錄音檔（錄音檔沒有畫面，只抽音軌）：抽音軌（切段放 audio/）、每隔幾秒取一張畫面交給 FrameProcessor。
/// 時間一律用影片內時間（00:12:30），音檔檔名 HHMMSS 也是影片內時間，轉文字的時間標記就會對上影片。
enum VideoImporter {
    enum ImportError: LocalizedError {
        case noAudio, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .noAudio: return "這個影片沒有聲音軌"
            case .exportFailed(let s): return "抽音軌失敗：\(s)"
            }
        }
    }

    /// progress：0～1 與目前在做什麼
    static func run(video: URL, settings: Settings, progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let hasVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        guard hasAudio else { throw ImportError.noAudio }

        // 會議資料夾：日期用影片檔的建立時間，名稱用檔名
        let created = (try? video.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let name = video.deletingPathExtension().lastPathComponent
        // 同名資料夾已存在就加 -2、-3，避免蓋掉之前匯入的
        let base = "\(f.string(from: created))-\(CaptureSession.sanitize(name))"
        var dir = URL(fileURLWithPath: settings.outputRoot).appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = URL(fileURLWithPath: settings.outputRoot).appendingPathComponent("\(base)-\(n)"); n += 1
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        var meta: [String: Any] = [
            "title": name, "app": hasVideo ? "（匯入錄影）" : "（匯入錄音）", "source": video.path,
            "startedAt": iso.string(from: created), "endedAt": iso.string(from: created.addingTimeInterval(duration)),
            "slideCount": 0, "micRecorded": false, "transcriptReady": false,
            "timeBase": "影片內時間（00:00:00 起算）",
        ]
        writeMeta(meta, dir: dir)

        // 1. 音軌：每段 segmentSeconds 秒，檔名＝影片內開始時間 HHMMSS
        let audioDir = dir.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let seg = max(60, settings.segmentSeconds)
        let segments = Int((duration / seg).rounded(.up))
        for i in 0..<segments {
            let start = Double(i) * seg
            let len = min(seg, duration - start)
            progress(Double(i) / Double(segments) * (hasVideo ? 0.3 : 1), "抽音軌 \(i + 1)/\(segments)")
            let out = audioDir.appendingPathComponent(hms(start, separator: "") + ".m4a")
            try await exportAudio(asset: asset, start: start, length: len, to: out)
        }

        // 2. 畫面：每 captureInterval 秒一張
        var slideCount = 0
        if hasVideo {
            let processor = FrameProcessor(dir: dir)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            let step = max(2, settings.captureInterval)
            var t = 0.0
            while t < duration {
                try Task.checkCancellation()
                if let (image, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                    processor.process(image, time: hms(t, separator: ":"))
                }
                progress(0.3 + 0.7 * t / duration, "看畫面 \(hms(t, separator: ":"))／\(hms(duration, separator: ":"))，簡報 \(processor.slideCount) 張")
                t += step
            }
            processor.finish()
            slideCount = processor.slideCount
        }
        meta["slideCount"] = slideCount
        writeMeta(meta, dir: dir)
        progress(1, "完成")
        return dir
    }

    private static func exportAudio(asset: AVAsset, start: Double, length: Double, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError.exportFailed("無法建立匯出工作")
        }
        ex.outputURL = url
        ex.outputFileType = .m4a
        ex.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                   duration: CMTime(seconds: length, preferredTimescale: 600))
        await ex.export()
        if ex.status != .completed { throw ImportError.exportFailed(ex.error?.localizedDescription ?? "status \(ex.status.rawValue)") }
    }

    static func hms(_ seconds: Double, separator: String) -> String {
        let s = Int(seconds)
        return String(format: "%02d\(separator)%02d\(separator)%02d", s / 3600, s / 60 % 60, s % 60)
    }

    private static func writeMeta(_ meta: [String: Any], dir: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("meta.json"))
        }
    }
}
