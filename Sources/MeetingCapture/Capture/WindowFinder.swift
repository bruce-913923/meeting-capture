import Foundation
import ScreenCaptureKit

/// 可以截的會議視窗（Teams 主視窗或分享內容的彈出視窗）
struct CaptureTarget: Identifiable, Hashable {
    let id: CGWindowID
    let app: String
    let title: String
    let size: CGSize
    var label: String { "\(title.isEmpty ? "(無標題)" : title)  \(Int(size.width))×\(Int(size.height))" }
}

enum WindowFinder {
    /// 會議 app 的名稱關鍵字（整個 app 的視窗都算）
    static let appKeywords = ["Teams", "zoom.us", "Zoom", "Webex", "Slack"]
    /// 瀏覽器裡的會議（例如 Google Meet）：瀏覽器視窗標題要含這些字
    static let browserApps = ["Google Chrome", "Microsoft Edge", "Safari", "Arc", "Firefox", "Brave Browser"]
    static let browserTitleKeywords = ["Meet", "meet.google", "Teams", "Zoom", "Webex", "webinar", "Webinar", "直播", "研討會"]

    static func candidates() async throws -> [CaptureTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows
            .filter { w in
                guard let name = w.owningApplication?.applicationName,
                      w.windowLayer == 0, w.frame.width > 400, w.frame.height > 300 else { return false }
                if appKeywords.contains(where: { name.localizedCaseInsensitiveContains($0) }) { return true }
                let title = w.title ?? ""
                return browserApps.contains(name) && browserTitleKeywords.contains { title.localizedCaseInsensitiveContains($0) }
            }
            .map { CaptureTarget(id: $0.windowID, app: $0.owningApplication?.applicationName ?? "",
                                 title: $0.title ?? "", size: $0.frame.size) }
            .sorted { $0.size.width * $0.size.height > $1.size.width * $1.size.height }
    }

    /// 找不到會議視窗時，讓使用者從所有視窗裡挑
    static func allWindows() async throws -> [CaptureTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width > 400 && $0.frame.height > 300 && $0.owningApplication != nil }
            .map { CaptureTarget(id: $0.windowID, app: $0.owningApplication?.applicationName ?? "",
                                 title: "\($0.owningApplication?.applicationName ?? "")：\($0.title ?? "")", size: $0.frame.size) }
    }

    /// 瀏覽器視窗（網頁研討會、直播等標題猜不到的會議）：直接列在選單第一層，不用鑽進「其他視窗」
    static func browserWindows() async throws -> [CaptureTarget] {
        try await allWindows().filter { browserApps.contains($0.app) }
    }

    static func scWindow(id: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.windows.first { $0.windowID == id }
    }
}

enum SystemAudio {
    /// 喇叭靜音時 ScreenCaptureKit 錄到的是無聲
    static func isOutputMuted() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "output muted of (get volume settings)"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// 解除靜音並把音量調到很小（使用者在提示視窗按了按鈕才會呼叫）
    static func unmuteQuietly() {
        Shell.run("/usr/bin/osascript", ["-e", "set volume output volume 3", "-e", "set volume without output muted"])
    }
}
