import Foundation
import CoreGraphics

/// 從整個會議視窗找出簡報區：分享畫面在 Teams 裡四周是純黑（或接近純黑）的舞台，
/// 所以找「四周一圈幾乎都是黑色的最大非黑區塊」。不用固定比例，版面怎麼變都跟著走。
enum SlideDetector {
    struct Result {
        let rect: CGRect?          // 原圖座標；nil 代表找不到可信的簡報區
        let reason: String
    }

    static let gridWidth = 240
    /// 舞台背景亮度上限：Teams 是純黑，Meet 是深灰，所以每張圖先估背景色再加一點容許值
    static func stageLevel(_ g: [UInt8]) -> UInt8 {
        var hist = [Int](repeating: 0, count: 256)
        for v in g { hist[Int(v)] += 1 }
        // 取 0～70 之間最常見的深色當舞台背景
        let bg = (0...70).max { hist[$0] < hist[$1] } ?? 0
        return UInt8(min(90, bg + 12))
    }

    static func detect(_ image: CGImage) -> Result {
        let W = gridWidth
        let H = max(1, Int(Double(image.height) / Double(image.width) * Double(W)))
        guard let gray = grayscale(image, width: W, height: H) else { return Result(rect: nil, reason: "無法縮圖") }
        let blackLevel = stageLevel(gray)

        var label = [Int32](repeating: 0, count: W * H)
        var best: (minX: Int, minY: Int, maxX: Int, maxY: Int)? = nil
        var bestArea = 0
        var next: Int32 = 0
        var stack: [Int] = []

        for start in 0..<(W * H) where gray[start] > blackLevel && label[start] == 0 {
            next += 1
            var minX = W, minY = H, maxX = 0, maxY = 0
            stack.append(start); label[start] = next
            while let p = stack.popLast() {
                let x = p % W, y = p / W
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < W, ny < H else { continue }
                    let q = ny * W + nx
                    if label[q] == 0 && gray[q] > blackLevel { label[q] = next; stack.append(q) }
                }
            }
            let area = (maxX - minX + 1) * (maxY - minY + 1)
            guard area >= W * H / 12 else { continue }                       // 太小不是簡報
            guard minX > 0, minY > 0, maxX < W - 1, maxY < H - 1 else { continue } // 貼到視窗邊緣
            guard ringBlackRatio(gray, W: W, H: H, minX: minX, minY: minY, maxX: maxX, maxY: maxY, level: blackLevel) >= 0.75 else { continue }
            if area > bestArea { bestArea = area; best = (minX, minY, maxX, maxY) }
        }

        guard var b = best else { return Result(rect: nil, reason: "找不到四周為黑邊的簡報區") }
        // 講者名字標籤等疊在黑邊上的小東西會把區塊撐大：從四邊往內修掉「大部分是黑色」的欄與列
        func darkRatio(col x: Int) -> Double {
            var n = 0; for y in b.minY...b.maxY where gray[y * W + x] <= blackLevel { n += 1 }
            return Double(n) / Double(b.maxY - b.minY + 1)
        }
        func darkRatio(row y: Int) -> Double {
            var n = 0; for x in b.minX...b.maxX where gray[y * W + x] <= blackLevel { n += 1 }
            return Double(n) / Double(b.maxX - b.minX + 1)
        }
        while b.maxX - b.minX > 10, darkRatio(col: b.minX) > 0.5 { b.minX += 1 }
        while b.maxX - b.minX > 10, darkRatio(col: b.maxX) > 0.5 { b.maxX -= 1 }
        while b.maxY - b.minY > 10, darkRatio(row: b.minY) > 0.5 { b.minY += 1 }
        while b.maxY - b.minY > 10, darkRatio(row: b.maxY) > 0.5 { b.maxY -= 1 }
        let sx = Double(image.width) / Double(W), sy = Double(image.height) / Double(H)
        // 縮圖一格約 sx 像素，往內收半格避免帶到黑邊
        let rect = CGRect(x: (Double(b.minX) + 0.5) * sx, y: (Double(b.minY) + 0.5) * sy,
                          width: Double(b.maxX - b.minX) * sx, height: Double(b.maxY - b.minY) * sy).integral
        return Result(rect: rect, reason: "ok")
    }

    /// 區塊外圍一圈有多少比例是黑色；越高代表簡報被完整包在黑色舞台裡、沒有被切到
    private static func ringBlackRatio(_ g: [UInt8], W: Int, H: Int, minX: Int, minY: Int, maxX: Int, maxY: Int, level blackLevel: UInt8) -> Double {
        var black = 0, total = 0
        let x0 = minX - 1, x1 = maxX + 1, y0 = minY - 1, y1 = maxY + 1
        for x in x0...x1 {
            for y in [y0, y1] { total += 1; if g[y * W + x] <= blackLevel { black += 1 } }
        }
        for y in (y0 + 1)..<y1 {
            for x in [x0, x1] { total += 1; if g[y * W + x] <= blackLevel { black += 1 } }
        }
        return total == 0 ? 0 : Double(black) / Double(total)
    }

    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: width * height)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buf : nil
    }

    /// 32×32 灰階簽章，用來判斷換頁
    static func signature(_ image: CGImage) -> [UInt8] {
        grayscale(image, width: 32, height: 32) ?? []
    }

    static func changed(_ a: [UInt8], _ b: [UInt8], threshold: Double = 6) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        var d = 0
        for i in 0..<a.count { d += abs(Int(a[i]) - Int(b[i])) }
        return Double(d) / Double(a.count) > threshold
    }
}
