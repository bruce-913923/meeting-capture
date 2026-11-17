import Foundation
import ScreenCaptureKit
import AVFoundation

/// 錄整台電腦播出的聲音（不用麥克風），每 segmentSeconds 秒切一個 m4a，
/// 中途當掉也只會壞最後一段。
final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    fileprivate let dir: URL
    private let segmentSeconds: Double
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var segmentStart: CMTime?
    fileprivate let queue = DispatchQueue(label: "audio.recorder")
    private(set) var peak: Float = 0          // 最近一段的最大音量，給介面判斷是否錄到聲音
    var onError: ((String) -> Void)?

    private let includeMic: Bool
    private var micRecorder: AudioRecorder?   // 麥克風另存一組檔案（mic/），避免兩路聲音時間軸互相干擾

    private let systemAudio: Bool

    /// systemAudio=false：實體會議，只錄麥克風（自己就是麥克風錄音器）
    init(dir: URL, segmentSeconds: Double = 600, includeMic: Bool = false, systemAudio: Bool = true) {
        self.dir = dir; self.segmentSeconds = segmentSeconds; self.includeMic = includeMic; self.systemAudio = systemAudio
    }

    func start() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        if includeMic {
            if #available(macOS 15.0, *) { cfg.captureMicrophone = true }
        }
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
        if includeMic, #available(macOS 15.0, *) {
            let mic = AudioRecorder(dir: dir.deletingLastPathComponent().appendingPathComponent("mic"), segmentSeconds: segmentSeconds)
            try FileManager.default.createDirectory(at: mic.dir, withIntermediateDirectories: true)
            try s.addStreamOutput(mic, type: .microphone, sampleHandlerQueue: mic.queue)
            micRecorder = mic
        }
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        if let mic = micRecorder {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in mic.queue.async { mic.finishSegment { c.resume() } } }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { self.finishSegment { c.resume() } }
        }
    }

    private func newSegment(at time: CMTime) {
        let f = DateFormatter(); f.dateFormat = "HHmmss"
        let url = dir.appendingPathComponent("\(f.string(from: Date())).m4a")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { return }
        let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
        i.expectsMediaDataInRealTime = true
        w.add(i)
        w.startWriting()
        w.startSession(atSourceTime: time)
        writer = w; input = i; segmentStart = time
    }

    fileprivate func finishSegment(_ done: @escaping () -> Void) {
        guard let w = writer, let i = input else { done(); return }
        writer = nil; input = nil; segmentStart = nil
        i.markAsFinished()
        w.finishWriting { done() }
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        if #available(macOS 15.0, *) { guard type == .audio || type == .microphone else { return } }
        else { guard type == .audio else { return } }
        let t = sb.presentationTimeStamp
        if writer == nil { newSegment(at: t) }
        if let start = segmentStart, CMTimeGetSeconds(t - start) >= segmentSeconds {
            finishSegment {}
            newSegment(at: t)
        }
        measurePeak(sb)
        if let i = input, i.isReadyForMoreMediaData { i.append(sb) }
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
        queue.async { self.finishSegment {} }
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
