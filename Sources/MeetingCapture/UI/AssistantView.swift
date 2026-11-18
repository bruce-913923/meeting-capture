import SwiftUI

/// 會議助手浮動面板：上面是自動更新的重點，下面是可以收合的討論區
struct AssistantView: View {
    @ObservedObject var a: Assistant
    @EnvironmentObject var state: AppState
    @State private var chatOpen = false
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    overview
                    if !chatOpen { blocks }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(maxHeight: chatOpen ? 170 : .infinity)
            Divider()
            chat
        }
        .font(.system(size: 13))
        .frame(minWidth: 300, minHeight: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if state.recordingDir == a.dir { Circle().fill(.red).frame(width: 8, height: 8) }
            Text("會議助手").fontWeight(.medium)
            Spacer()
            if a.updating { ProgressView().controlSize(.small) }
            Text(updatedLine).font(.caption).foregroundStyle(.secondary)
            Button { Task { await a.tick(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("有新內容就馬上整理").disabled(a.updating)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var updatedLine: String {
        guard a.saved.coveredUntil >= 0 else { return "" }
        var s = "重點更新到 " + Clock.add(a.saved.coveredUntil, 0).prefix(5)
        if a.transcriptUntil > a.saved.coveredUntil { s += "　逐字稿到 " + Clock.add(a.transcriptUntil, 0).prefix(5) }
        return s
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !a.status.isEmpty { Text(a.status).font(.caption).foregroundStyle(.secondary) }
            Text("目前結論與待確認").fontWeight(.medium)
            if a.saved.overview.isEmpty {
                Text(a.updating ? "整理中…" : "（還沒有）").foregroundStyle(.secondary)
            }
            ForEach(a.saved.overview, id: \.self) { p in
                Text("· " + p.text).foregroundStyle(p.pending ? Color.orange : Color.primary).textSelection(.enabled)
            }
        }
    }

    private var blocks: some View {
        VStack(alignment: .leading, spacing: 8) {
            let shown = a.saved.blocks.reversed().filter { !$0.points.isEmpty }
            if !shown.isEmpty { Divider() }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, b in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(b.from)–\(b.to)").font(.caption).foregroundStyle(.secondary)
                    ForEach(b.points, id: \.self) { Text("· " + $0).textSelection(.enabled) }
                }
            }
        }
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { chatOpen.toggle() } } label: {
                HStack {
                    Image(systemName: chatOpen ? "chevron.down" : "chevron.up")
                    Text(a.saved.chat.isEmpty ? "討論區" : "討論區（問過 \(a.saved.chat.filter(\.fromUser).count) 題）")
                    Spacer()
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            if chatOpen {
                HStack(spacing: 6) {
                    quick("剛剛 5 分鐘講了什麼")
                    quick("還沒結論的事")
                    if !state.settings.myName.isEmpty { quick("有人提到我嗎", "有人提到我（\(state.settings.myName)）嗎？提到什麼、要我做什麼？") }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(a.saved.chat) { m in
                                Text(m.text)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, m.fromUser ? 8 : 0).padding(.vertical, m.fromUser ? 4 : 0)
                                    .background(m.fromUser ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .frame(maxWidth: .infinity, alignment: m.fromUser ? .trailing : .leading)
                                    .id(m.id)
                            }
                            if a.asking { HStack { ProgressView().controlSize(.small); Text("想一下…").foregroundStyle(.secondary) }.id("asking") }
                        }
                    }
                    .frame(minHeight: 120)
                    .onChange(of: a.saved.chat.count) { _ in
                        if let last = a.saved.chat.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                HStack {
                    TextField("例如：他剛剛說的第二個方案是什麼？", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .onSubmit(send)
                    Button(action: send) { Image(systemName: "paperplane") }
                        .disabled(a.asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func quick(_ label: String, _ q: String? = nil) -> some View {
        Button(label) { Task { await a.ask(q ?? label) } }
            .font(.caption).disabled(a.asking)
    }

    private func send() {
        let q = question
        question = ""
        Task { await a.ask(q) }
    }
}
