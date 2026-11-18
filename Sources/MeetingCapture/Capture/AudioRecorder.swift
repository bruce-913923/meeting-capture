import Foundation
import ScreenCaptureKit
import AVFoundation

/// 錄整台電腦播出的聲音（或只錄麥克風），每 segmentSeconds 秒切一個 m4a（正式逐字稿用），
/// 中途當掉也只會壞最後一段。
/// 另外每 draftSeconds 秒存一份「草稿」小檔到 live/，前後重疊 draftOverlap 秒，給會議中的即時逐字稿用。
final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    /// 一個正在寫的音檔
    private final class Chunk {
        let url: URL, writer: AVAssetWriter, input: AVAssetWriterInput, start: CMTime
        init?(url: URL, at time: CMTime) {
            guard let w = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { return nil }
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            i.expectsMediaDataInRealTime = true
            w.add(i)
            guard w.startWriting() else { return nil }
            w.startSession(atSourceTime: time)
            self.url = url; writer = w; input = i; start = time
        }
        func append(_ sb: CMSampleBuffer) { if input.isReadyForMoreMediaData { input.append(sb) } }
        func finish(_ done: @escaping () -> Void) { input.markAsFinished(); writer.finishWriting(completionHandler: done) }
    }

    fileprivate let dir: URL
    private let segmentSeconds: Double
    private var stream: SCStream?
    private var segment: Chunk?
    private var drafts: [Chunk] = []
    fileprivate let queue = DispatchQueue(label: "audio.recorder")
    private(set) var peak: Float = 0          // 最近一段的最大音量，給介面判斷是否錄到聲音
    var onError: ((String) -> Void)?
    /// 一段正式錄音寫完（錄音中途；結束擷取時的最後一段不通知，交給整場轉文字）
    var onSegmentClosed: ((URL) -> Void)?
    /// 一份草稿小檔寫完
    var onDraftClosed: ((URL) -> Void)?
    /// 草稿長度與重疊；draftSeconds = 0 表示不存草稿
    var draftSeconds: Double = 120
    var draftOverlap: Double = 5

    private let systemAudio: Bool
    private var draftDir: URL { dir.deletingLastPathComponent().appendingPathComponent("live").appendingPathComponent(dir.lastPathComponent) }

    /// systemAudio=false：實體會議，只錄麥克風（自己就是麥克風錄音器）
    init(dir: URL, segmentSeconds: Double = 600, systemAudio: Bool = true) {
        self.dir = dir; self.segmentSeconds = segmentSeconds; self.systemAudio = systemAudio
    }

    func start() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if draftSeconds > 0 { try? FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = systemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        if !systemAudio {
            guard #available(macOS 15.0, *) else { throw CaptureError.micNeedsMacOS15 }
            cfg.captureMicrophone = true
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            return
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                // 沒寫完的草稿直接丟掉：結束後會轉正式逐字稿
                for d in self.drafts { d.finish {} }
                self.drafts = []
                self.closeSegment(notify: false) { c.resume() }
            }
        }
    }

    private static func name(_ dir: URL) -> URL {
        let f = DateFormatter(); f.dateFormat = "HHmmss"
        return dir.appendingPathComponent("\(f.string(from: Date())).m4a")
    }

    private func closeSegment(notify: Bool, _ done: @escaping () -> Void = {}) {
        guard let seg = segment else { done(); return }
        segment = nil
        seg.finish { [weak self] in
            if notify { self?.onSegmentClosed?(seg.url) }
            done()
        }
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        if #available(macOS 15.0, *) { guard type == .audio || type == .microphone else { return } }
        else { guard type == .audio else { return } }
        let t = sb.presentationTimeStamp
        if let seg = segment, CMTimeGetSeconds(t - seg.start) >= segmentSeconds { closeSegment(notify: true) }
        if segment == nil { segment = Chunk(url: Self.name(dir), at: t) }
        if draftSeconds > 0 { feedDrafts(sb, at: t) }
        measurePeak(sb)
        segment?.append(sb)
    }

    /// 草稿：每 (draftSeconds - draftOverlap) 秒開一個新檔，每個檔滿 draftSeconds 秒就收尾，所以相鄰兩檔重疊 draftOverlap 秒
    private func feedDrafts(_ sb: CMSampleBuffer, at t: CMTime) {
        if drafts.last.map({ CMTimeGetSeconds(t - $0.start) >= draftSeconds - draftOverlap }) ?? true,
           let d = Chunk(url: Self.name(draftDir), at: t) {
            drafts.append(d)
        }
        for d in drafts { d.append(sb) }
        while let first = drafts.first, CMTimeGetSeconds(t - first.start) >= draftSeconds {
            drafts.removeFirst()
            first.finish { [weak self] in self?.onDraftClosed?(first.url) }
        }
    }

    private func measurePeak(_ sb: CMSampleBuffer) {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0; var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
        guard let p = ptr, len >= 4 else { return }
        var m: Float = 0
        p.withMemoryRebound(to: Float.self, capacity: len / 4) { f in
            for k in stride(from: 0, to: len / 4, by: 16) { m = max(m, abs(f[k])) }
        }
        peak = max(peak * 0.995, m)
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        onError?("錄音中斷：\(error.localizedDescription)")
        queue.async { self.closeSegment(notify: false) }
    }
}

enum CaptureError: LocalizedError {
    case noDisplay, noWindow, micNeedsMacOS15
    var errorDescription: String? {
        switch self {
        case .micNeedsMacOS15: return "錄麥克風需要 macOS 15 以上"
        case .noDisplay: return "找不到螢幕"
        case .noWindow: return "找不到要截的會議視窗"
        }
    }
}
