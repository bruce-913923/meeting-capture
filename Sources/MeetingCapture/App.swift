import SwiftUI

@main
struct MeetingCaptureApp: App {
    @StateObject private var state = AppState()

    init() { CLI.runIfRequested() }

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(state)
        } label: {
            Image(systemName: state.phase == .recording ? "record.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Text(state.statusLine)
        if let q = state.queueLine { Text(q) }
        if let w = state.warning { Text("⚠️ \(w)") }
        if !state.hasScreenPermission {
            Text("系統設定 › 隱私權與安全性 › 螢幕與系統錄音：把 Meeting Capture 打開。")
            Text("如果它已經是開的，那是舊版留下的：先選它按「−」刪掉，再按「＋」加入 /Applications 裡的 Meeting Capture。")
            Button("打開螢幕錄音設定") { state.openScreenPermissionSettings() }
            Button("設定好了，重新開啟 app") { state.relaunch() }
            Divider()
        }
        if state.phase != .recording {
            Text("提醒：線上會議錄的是電腦播出的聲音，喇叭不能靜音（音量開最小即可）")
        }
        Divider()
        switch state.phase {
        case .recording:
            if state.micOn { Text("🎙 正在錄現場聲音") }
            Button("結束擷取") { Task { await state.stop() } }
            if let dir = state.recordingDir {
                Button("在 \(state.providerName) 討論這場會議") { state.discuss(dir: dir, resume: false) }
                if Discussion.hasPrevious(dir) {
                    Button("繼續上次的討論（\(state.providerName)）") { state.discuss(dir: dir, resume: true) }
                }
            }
            if !state.isPhysical {
                if #available(macOS 15.0, *) {
                    Toggle("錄現場麥克風（現場有人講話、會後討論時打開）", isOn: Binding(
                        get: { state.micOn },
                        set: { on in Task { await state.setMic(on) } }))
                    .disabled(state.micBusy)
                } else {
                    Text("錄現場麥克風需要 macOS 15 以上")
                }
            }
        case .importing:
            Text("匯入完成後會排進背景轉文字，轉好跳出整理視窗")
        default:
            Menu("開始擷取") {
                if !state.windows.isEmpty {
                    Text("會議軟體")
                    ForEach(state.windows) { w in
                        Button(w.label) { Task { await state.start(target: w) } }
                    }
                }
                if !state.browserWindows.isEmpty {
                    Divider()
                    Text("瀏覽器（截的是最前面那個分頁，會議分頁要留在前面）")
                    ForEach(state.browserWindows) { w in
                        Button(w.label) { Task { await state.start(target: w) } }
                    }
                }
                Divider()
                Menu("其他視窗") {
                    ForEach(state.otherWindows) { w in
                        Button(w.label) { Task { await state.start(target: w) } }
                    }
                }
                Button("重新找視窗") { Task { await state.refreshWindows() } }
            }
            Text("現場有人講話時，開始後再打開「錄現場麥克風」")
            Button("只錄麥克風（實體會議，沒開會議軟體）") { Task { await state.start(physical: true) } }
            Button("匯入錄影或錄音檔…") { state.importVideo() }
        }
        Divider()
        if state.phase != .recording {
            Menu("整理會議（✓＝整理過）") {
                ForEach(AppState.meetings(root: state.settings.outputRoot)) { m in
                    Button(m.label) { state.lastDir = m.dir; state.openFinish(dir: m.dir) }
                }
                Divider()
                Button("開啟其他會議資料夾…") { state.chooseMeeting() }
            }
            if let dir = state.lastDir {
                Button(state.isQueued(dir) ? "轉文字中：\(dir.lastPathComponent.prefix(30))" : "重新轉文字：\(dir.lastPathComponent.prefix(30))") { state.transcribe(dir: dir, fresh: true) }
                    .disabled(state.isQueued(dir))
                Button("打開會議資料夾：\(dir.lastPathComponent.prefix(30))") { state.openFolder(dir) }
            }
        }
        Button("設定…") { state.openSettings() }
        Divider()
        Button("結束 Meeting Capture") { NSApp.terminate(nil) }
    }
}
