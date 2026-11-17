import Foundation
import ScreenCaptureKit
import Vision
import ImageIO
import UniformTypeIdentifiers

/// 處理一張會議畫面：換頁時存整個畫面原圖與切出的簡報區，並 OCR 字幕（簡報區以外的文字）。
/// 即時擷取與錄影匯入共用；time 是要寫進紀錄的時間（即時＝時鐘，錄影＝影片內時間）。
final class FrameProcessor {
    struct SlideEntry: Codable {
        let index: Int
        let time: String
        let frame: String
        let slide: String?
        let note: String?
    }

    private let dir: URL
    private var lastSig: [UInt8] = []
    private var entries: [SlideEntry] = []
    private var seenLines: [String] = []
    private var seenSet = Set<String>()
    private let captions: FileHandle?
    private(set) var slideCount = 0

    init(dir: URL) {
        self.dir = dir
        for sub in ["frames", "slides"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let capURL = dir.appendingPathComponent("captions.txt")
        FileManager.default.createFile(atPath: capURL.path, contents: nil)
        captions = try? FileHandle(forWritingTo: capURL)
    }

    func process(_ image: CGImage, time ts: String) {
        let det = SlideDetector.detect(image)
        let slideImage = det.rect.flatMap { image.cropping(to: $0) }
        let sig = SlideDetector.signature(slideImage ?? image)

        if SlideDetector.changed(lastSig, sig) {
            lastSig = sig
            slideCount += 1
            let n = String(format: "%03d", slideCount)
            let stamp = ts.replacingOccurrences(of: ":", with: "")
            let framePath = "frames/\(n)_\(stamp).jpg"
            FrameCapture.saveJPEG(image, to: dir.appendingPathComponent(framePath))
            var slidePath: String? = nil
            if let s = slideImage {
                slidePath = "slides/\(n)_\(stamp).jpg"
                FrameCapture.saveJPEG(s, to: dir.appendingPathComponent(slidePath!))
            }
            entries.append(SlideEntry(index: slideCount, time: ts, frame: framePath, slide: slidePath,
                                      note: slideImage == nil ? det.reason + "，只存整個畫面" : nil))
            writeIndex()
            appendCaption("[\(ts)] <<畫面 \(n)>>")
        }
        ocrCaptions(image, excluding: det.rect, time: ts)
    }

    func finish() {
        try? captions?.close()
        writeIndex()
    }

    /// 字幕位置會隨版面變，所以 OCR 整個畫面（簡報區塗黑），去重後依時間記下。
    private func ocrCaptions(_ image: CGImage, excluding rect: CGRect?, time: String) {
        var source = image
        if let r = rect, let masked = FrameCapture.masked(image, rect: r) { source = masked }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hant", "en-US"]
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: source, options: [:]).perform([req])
        let lines = (req.results ?? [])
            .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 4 }
        // 最後兩行常是還在變動的字幕，先不記
        for line in lines.dropLast(2) where !seenSet.contains(line) {
            seenSet.insert(line); seenLines.append(line)
            if seenLines.count > 600 { seenSet.remove(seenLines.removeFirst()) }
            appendCaption("[\(time)] \(line)")
        }
    }

    private func appendCaption(_ s: String) {
        captions?.write((s + "\n").data(using: .utf8)!)
    }

    private func writeIndex() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let d = try? enc.encode(entries) { try? d.write(to: dir.appendingPathComponent("slides/index.json")) }
    }
}

/// 定時截會議視窗，交給 FrameProcessor 處理。
final class FrameCapture {
    private let target: CaptureTarget
    private let interval: TimeInterval
    private let processor: FrameProcessor
    private var task: Task<Void, Never>?
    var slideCount: Int { processor.slideCount }
    var onError: ((String) -> Void)?

    init(dir: URL, target: CaptureTarget, interval: TimeInterval = 4) {
        self.target = target; self.interval = interval
        processor = FrameProcessor(dir: dir)
    }

    func start() {
        task = Task.detached(priority: .utility) { [weak self] in
            var failures = 0
            while let self, !Task.isCancelled {
                do {
                    try await self.tick()
                    failures = 0
                } catch {
                    failures += 1
                    if failures == 3 { self.onError?("截圖失敗：\(error.localizedDescription)") }
                }
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        processor.finish()
    }

    private func tick() async throws {
        guard let win = try await WindowFinder.scWindow(id: target.id) else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        cfg.width = Int(win.frame.width * scale)
        cfg.height = Int(win.frame.height * scale)
        cfg.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        processor.process(image, time: Self.clock())
    }

    static func clock() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
    }

    static func saveJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    static func masked(_ image: CGImage, rect: CGRect) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        // CGContext 原點在左下，rect 是左上原點座標
        ctx.fill(CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY, width: rect.width, height: rect.height))
        return ctx.makeImage()
    }
}
