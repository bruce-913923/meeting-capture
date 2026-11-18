import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable { case idle, recording, importing(String), error(String) }

    @Published var phase: Phase = .idle
    @Published var settings = Settings.load() { didSet { settings.save() } }
    @Published var windows: [CaptureTarget] = []
    @Published var otherWindows: [CaptureTarget] = []
    @Published var browserWindows: [CaptureTarget] = []
    private var windowTicker: Timer?
    @Published var startedAt: Date?
    @Published var slideCount = 0
    @Published var hearingAudio = false
    @Published var lastDir: URL?
    @Published var warning: String?
    /// 線上會議錄音中，現場麥克風是否開著（錄音中隨時可切換）
    @Published var micOn = false
    @Published var micBusy = false
    @Published var isPhysical = false
    /// 螢幕錄音權限：沒有時找不到任何視窗，要明講，不能顯示成「沒看到會議視窗」
    @Published var hasScreenPermission = CGPreflightScreenCaptureAccess()
    private var askedPermission = false

    private var session: CaptureSession?
    private var ticker: Timer?
    /// 轉文字在背景排隊，不佔 phase：轉上一場時照樣可以開始擷取下一場。
    /// 一次只跑一個，避免搶 GPU；會議中的草稿最優先，其次是錄好的段落，最後才是整場收尾
    enum TJob: Equatable {
        case draft(dir: URL, file: URL)
        case segment(dir: URL, file: URL)
        case full(dir: URL, fresh: Bool)
        var dir: URL { switch self { case .draft(let d, _), .segment(let d, _), .full(let d, _): return d } }
        var rank: Int { switch self { case .draft: return 0; case .segment: return 1; case .full: return 2 } }
        var isFull: Bool { if case .full = self { return true }; return false }
    }
    @Published var jobs: [TJob] = []
    @Published var runningJob: TJob?
    /// 已拆成逐段的整場工作：第二次輪到時就直接收尾，避免某段一直轉失敗時無限重排
    private var expanded: Set<URL> = []
    /// 錄音中轉好的場次：等這場結束再跳整理視窗，不在會議中打斷
    private var waitingFinish: [URL] = []
    private var finishWindows: [URL: NSWindow] = [:]
    private var settingsWindow: NSWindow?

    init() {
        lastDir = Self.latestMeetingDir(root: settings.outputRoot)
        Task { await refreshWindows() }
        // 視窗清單每 5 秒更新一次：app 開著之後才開的會議（例如瀏覽器研討會）也要選得到
        windowTicker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase != .recording, self.hasScreenPermission else { return }
                await self.refreshWindows()
            }
        }
    }

    var statusLine: String {
        switch phase {
        case .idle:
            if !hasScreenPermission { return "⚠️ 沒有螢幕錄音權限，截不到會議畫面" }
            return windows.isEmpty && browserWindows.isEmpty ? "待命：沒看到會議視窗（可從「開始擷取 › 其他視窗」挑）" : "待命"
        case .recording:
            let secs = Int(Date().timeIntervalSince(startedAt ?? Date()))
            if isPhysical {
                return String(format: "錄音中（實體會議）%02d:%02d　%@", secs / 60, secs % 60, hearingAudio ? "有收到聲音" : "⚠️ 還沒收到聲音")
            }
            return String(format: "擷取中 %02d:%02d　簡報 %d 張　%@", secs / 60, secs % 60, slideCount,
                          hearingAudio ? "有收到聲音" : "⚠️ 還沒收到聲音")
        case .importing(let s): return "匯入錄影中：\(s)"
        case .error(let s): return "錯誤：\(s)"
        }
    }

    /// 選單上的背景轉文字狀態
    var queueLine: String? {
        // 只列要收尾的場次；錄音中的邊錄邊轉不顯示
        let dirs = ([runningJob].compactMap { $0 } + jobs).filter { $0.dir != session?.dir }.map(\.dir)
        var seen: [URL] = []
        for d in dirs where !seen.contains(d) { seen.append(d) }
        guard let d = seen.first else { return nil }
        let more = seen.count > 1 ? "（後面還有 \(seen.count - 1) 場）" : ""
        return "背景轉文字：\(Self.displayName(d).prefix(28))\(more)"
    }

    static func displayName(_ dir: URL) -> String {
        let t = MeetingFiles.title(dir); return t.isEmpty ? dir.lastPathComponent : t
    }

    func refreshWindows() async {
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        do {
            windows = try await WindowFinder.candidates()
            otherWindows = try await WindowFinder.allWindows()
            browserWindows = try await WindowFinder.browserWindows().filter { b in !windows.contains { $0.id == b.id } }
            hasScreenPermission = true
        } catch {
            windows = []; otherWindows = []; browserWindows = []
            if !CGPreflightScreenCaptureAccess() { hasScreenPermission = false }
            else { warning = "找視窗失敗：\(error.localizedDescription)" }
        }
        // 第一次發現沒權限時，讓系統把本 app 加進「螢幕與系統錄音」清單
        if !hasScreenPermission && !askedPermission { askedPermission = true; CGRequestScreenCaptureAccess() }
    }

    func openScreenPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        Shell.run("/bin/sh", ["-c", "(sleep 1; open \"\(path)\") >/dev/null 2>&1 &"])
        NSApp.terminate(nil)
    }

    // MARK: 開始與結束

    /// physical=true：實體會議，只錄麥克風、不截圖
    func start(target: CaptureTarget? = nil, physical: Bool = false) async {
        await refreshWindows()
        let t = physical ? nil : (target ?? windows.first)
        if !physical && t == nil {
            phase = .error("找不到會議視窗，請先加入會議，或從「選擇要截的視窗 › 其他視窗」挑一個"); return
        }
        if !physical && SystemAudio.isOutputMuted() {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Mac 喇叭目前是靜音，這樣錄不到會議聲音"
            a.informativeText = "app 錄的是電腦播放出來的聲音，喇叭靜音時會錄到一片無聲。\n\n只要解除靜音就好，音量開到最小也錄得到，旁邊的人聽不到；麥克風不用開。"
            a.addButton(withTitle: "解除靜音並調到最小音量，開始錄")
            a.addButton(withTitle: "取消")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            SystemAudio.unmuteQuietly()
        }
        do {
            let s = try CaptureSession(target: t, settings: settings)
            s.onError = { [weak self] msg in Task { @MainActor in self?.warning = msg } }
            let dir = s.dir
            s.onSegmentClosed = { [weak self] url in Task { @MainActor in self?.enqueue(.segment(dir: dir, file: url)) } }
            s.onDraftClosed = { [weak self] url in Task { @MainActor in self?.enqueue(.draft(dir: dir, file: url)) } }
            try await s.start()
            session = s; startedAt = Date(); slideCount = 0; hearingAudio = false; warning = nil; micOn = false
            phase = .recording
            isPhysical = physical
            var ticks = 0, warnedMute = false, warnedSilent = false
            ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let s = self.session else { return }
                    ticks += 1
                    self.slideCount = s.slideCount
                    if s.audioPeak > 0.001 { self.hearingAudio = true }
                    // 每 10 秒檢查喇叭是否被切回靜音
                    if !physical, ticks % 5 == 0, SystemAudio.isOutputMuted(), !warnedMute {
                        warnedMute = true
                        self.warning = "喇叭被切成靜音了，現在錄不到聲音"
                        self.notify("喇叭被切成靜音了", "會議聲音錄不到，請解除靜音（音量開最小即可）")
                    } else if !SystemAudio.isOutputMuted() { warnedMute = false }
                    // 開始 1 分鐘還沒收到聲音
                    if ticks == 30, !self.hearingAudio, !warnedSilent {
                        warnedSilent = true
                        self.notify("1 分鐘都沒收到聲音", physical ? "請確認麥克風權限與收音" : "請確認喇叭沒有靜音、會議有聲音")
                    }
                    self.objectWillChange.send()
                }
            }
        } catch {
            phase = .error("無法開始擷取：\(error.localizedDescription)（第一次使用請到 系統設定 › 隱私權與安全性 › 螢幕與系統錄音 允許本 app）")
        }
    }

    /// 線上會議錄音中打開／關掉現場麥克風
    func setMic(_ on: Bool) async {
        guard let s = session, !isPhysical, !micBusy else { return }
        micBusy = true; defer { micBusy = false }
        do { try await s.setMic(on); micOn = s.micOn }
        catch { micOn = s.micOn; warning = "麥克風打不開：\(error.localizedDescription)" }
    }

    func stop() async {
        guard let s = session else { return }
        ticker?.invalidate(); ticker = nil
        await s.stop()
        session = nil; micOn = false
        lastDir = s.dir
        phase = .idle
        transcribe(dir: s.dir)
        // 錄這場時轉好的前幾場，現在才跳整理視窗
        for d in waitingFinish { openFinish(dir: d) }
        waitingFinish = []
    }

    /// 整場轉文字（結束擷取、匯入、重新轉文字）。fresh＝清掉之前逐段轉好的結果重轉
    func transcribe(dir: URL, fresh: Bool = false) {
        guard !jobs.contains(where: { $0.isFull && $0.dir == dir }) else { return }
        enqueue(.full(dir: dir, fresh: fresh))
    }

    func isQueued(_ dir: URL) -> Bool {
        (runningJob.map { $0.isFull && $0.dir == dir } ?? false) || jobs.contains { $0.isFull && $0.dir == dir }
    }

    private func enqueue(_ job: TJob) {
        guard runningJob != job, !jobs.contains(job) else { return }
        jobs.append(job)
        if runningJob == nil { Task { await runQueue() } }
    }

    private func runQueue() async {
        while let i = jobs.indices.min(by: { jobs[$0].rank < jobs[$1].rank || (jobs[$0].rank == jobs[$1].rank && $0 < $1) }) {
            let job = jobs.remove(at: i)
            runningJob = job
            let s = settings
            switch job {
            case .draft(let dir, let file), .segment(let dir, let file):
                let ok = await Transcriber.runLive(file: file, dir: dir, settings: s)
                if !ok, case .segment = job { warning = "會議中轉文字失敗一段，結束後會再轉一次" }
                runningJob = nil
            case .full(let dir, let fresh):
                // 逐檔轉的引擎：拆成一段一段排隊，中間可以插入會議中的草稿
                let todo = expanded.contains(dir) ? [] : await Transcriber.pending(dir: dir, settings: s, fresh: fresh)
                if !todo.isEmpty {
                    expanded.insert(dir)
                    jobs.append(contentsOf: todo.map { TJob.segment(dir: dir, file: $0) })
                    jobs.append(.full(dir: dir, fresh: false))
                    runningJob = nil
                    continue
                }
                expanded.remove(dir)
                var failure: String?
                do { try await Transcriber.transcribe(dir: dir, settings: s) }
                catch { failure = error.localizedDescription }
                if failure == nil { Transcriber.clearLive(dir: dir) }
                runningJob = nil
                finished(dir: dir, failure: failure)
            }
        }
    }

    private func finished(dir: URL, failure: String?) {
        let name = Self.displayName(dir)
        if let failure {
            warning = "轉文字失敗（\(name)）：\(failure)"
            notify("轉文字失敗：\(name)", failure)
        }
        if phase == .recording {
            waitingFinish.append(dir)
            if failure == nil { notify("「\(name)」文字已轉好", "這場結束後再跳出整理視窗；也可以從「整理會議」選單先打開") }
        } else {
            if failure == nil { notify("「\(name)」文字已轉好", "接著選擇整理方式") }
            openFinish(dir: dir)   // 失敗也開：仍可只用字幕與截圖整理
        }
    }

    // MARK: 視窗

    func openFinish(dir: URL) {
        waitingFinish.removeAll { $0 == dir }
        finishWindows[dir]?.close()
        let view = FinishView(dir: dir).environmentObject(self)
        finishWindows[dir] = makeWindow(title: "整理會議：\(dir.lastPathComponent)", view: view, size: NSSize(width: 620, height: 560))
    }

    func openSettings() {
        settingsWindow?.close()
        settingsWindow = makeWindow(title: "Meeting Capture 設定", view: SettingsView().environmentObject(self), size: NSSize(width: 620, height: 640))
    }

    private func makeWindow<V: View>(title: String, view: V, size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return w
    }

    func openFolder(_ url: URL?) {
        if let url { NSWorkspace.shared.open(url) }
    }

    // MARK: 小工具

    func notify(_ title: String, _ body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "'") }
        Shell.run("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
    }

    func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = message; a.runModal()
    }

    static func latestMeetingDir(root: String) -> URL? { meetings(root: root, limit: 1).first?.dir }

    /// 會議資料夾清單，依 meta.json 的開始時間由新到舊（不靠資料夾名稱排序）
    static func meetings(root: String, limit: Int = 10) -> [MeetingEntry] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let iso = ISO8601DateFormatter()
        let list: [MeetingEntry] = items.compactMap { dir in
            let metaURL = dir.appendingPathComponent("meta.json")
            guard fm.fileExists(atPath: metaURL.path) else { return nil }
            let o = (try? Data(contentsOf: metaURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let started = (o["startedAt"] as? String).flatMap { iso.date(from: $0) }
                ?? (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let outputs = ["summary.md", "minutes.md", "article.md", "output.md", "notion-page.md"]
            let done = outputs.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
            return MeetingEntry(dir: dir, title: o["title"] as? String ?? dir.lastPathComponent, started: started, organized: done)
        }
        return Array(list.sorted { $0.started > $1.started }.prefix(limit))
    }

    /// 選單「匯入錄影或錄音檔…」：抽音軌與簡報 → 轉文字 → 跳出整理視窗
    func importVideo() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false
        p.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audio]
        p.message = "選會議錄影或錄音檔（mp4、mov、m4a、mp3、wav 等）"
        guard p.runModal() == .OK, let url = p.url else { return }
        phase = .importing("準備中")
        Task {
            do {
                let dir = try await VideoImporter.run(video: url, settings: settings) { frac, msg in
                    Task { @MainActor in self.phase = .importing("\(Int(frac * 100))%　\(msg)") }
                }
                lastDir = dir
                phase = .idle
                transcribe(dir: dir)
            } catch {
                phase = .error("匯入失敗：\(error.localizedDescription)")
                notify("匯入錄影失敗", error.localizedDescription)
            }
        }
    }

    /// 選單「開啟其他會議資料夾…」
    func chooseMeeting() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: settings.outputRoot)
        p.message = "選一場會議的資料夾（裡面要有 meta.json 或錄音、逐字稿）"
        guard p.runModal() == .OK, let url = p.url else { return }
        lastDir = url
        openFinish(dir: url)
    }
}

struct MeetingEntry: Identifiable {
    let dir: URL
    let title: String
    let started: Date
    let organized: Bool
    var id: String { dir.path }
    var label: String {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
        return "\(organized ? "✓ " : "　 ")\(f.string(from: started))　\(title.prefix(28))"
    }
}
