import SwiftUI

/// Bir oturumla aranızdaki konuşmanın tamamı; altta mesaj kutusu.
struct ChatWindow: View {
    @Environment(ShiftStore.self) private var store
    let sessionID: String
    @State private var conversation: Conversation?

    private var shift: Shift? { store.shifts.first { $0.id == sessionID } }

    var body: some View {
        VStack(spacing: 0) {
            if let shift {
                ChatHeader(shift: shift)
                Divider()
                if let conversation {
                    ChatTranscript(conversation: conversation)
                } else {
                    Spacer()
                }
                Divider()
                MessageComposer(shift: shift, autofocus: true)
                    .padding(12)
                    .background(Theme.card)
            } else {
                ContentUnavailableView(String(localized: "This session has ended"), systemImage: "moon.zzz")
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .background(Theme.window)
        .navigationTitle(shift.map { String(localized: "Chat · \($0.project)") } ?? "Vardiya")
        .onAppear(perform: load)
        .onChange(of: shift?.transcriptURL) { _, _ in load() }
        .onDisappear { conversation?.stop() }
    }

    private func load() {
        guard conversation == nil, let url = shift?.transcriptURL else { return }
        let c = Conversation(url: url)
        conversation = c
        c.start()
    }
}

private struct ChatHeader: View {
    let shift: Shift

    var body: some View {
        let a = shift.main.activity
        HStack(spacing: 10) {
            Image(systemName: a.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(a.tint)
                .frame(width: 32, height: 32)
                .background(a.softTint, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(shift.project)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.text)
                if let title = shift.title {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            StatusPill(activity: a)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.card)
    }
}

/// Mesajlar; art arda gelen araç adımları tek satırda toplanır.
private struct ChatTranscript: View {
    let conversation: Conversation
    /// İlk yüklemede en sona animasyonsuz atla; sonraki yeni mesajlarda yumuşak kaydır.
    @State private var didInitialScroll = false

    private enum Row: Identifiable {
        case message(ChatItem)
        case tools([ChatItem])

        var id: String {
            switch self {
            case .message(let m): m.id
            case .tools(let t): "tools-" + (t.first?.id ?? "")
            }
        }
    }

    private var rows: [Row] {
        var out: [Row] = []
        var pending: [ChatItem] = []
        for item in conversation.items {
            if case .tool = item.kind {
                pending.append(item)
            } else {
                if !pending.isEmpty { out.append(.tools(pending)); pending = [] }
                out.append(.message(item))
            }
        }
        if !pending.isEmpty { out.append(.tools(pending)) }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if conversation.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(30)
                    } else if conversation.items.isEmpty {
                        Text("No messages yet")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(30)
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .message(let m): MessageBubble(item: m)
                        case .tools(let t): ToolGroup(items: t)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            // Pencere açılınca en yeni mesajlardan başla
            .defaultScrollAnchor(.bottom)
            .onAppear { jumpToBottom(proxy) }
            .onChange(of: conversation.items.count) { _, _ in
                if didInitialScroll {
                    withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                } else {
                    jumpToBottom(proxy)
                }
            }
            .onChange(of: conversation.items.map(\.pending)) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

extension ChatTranscript {
    /// LazyVStack satırları geç yerleştirdiği için iki tur bekleyip tekrar kaydırıyoruz.
    fileprivate func jumpToBottom(_ proxy: ScrollViewProxy) {
        guard !conversation.items.isEmpty else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
        DispatchQueue.main.async {
            proxy.scrollTo("bottom", anchor: .bottom)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                proxy.scrollTo("bottom", anchor: .bottom)
                didInitialScroll = true
            }
        }
    }
}

private struct MessageBubble: View {
    let item: ChatItem

    var body: some View {
        let isUser = item.kind == .user
        HStack(alignment: .bottom) {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                Text(markdown(item.text))
                    .font(.system(size: 13))
                    .foregroundStyle(isUser && !item.pending ? .white : Theme.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isUser ? (item.pending ? Theme.mutedSoft : Theme.accent) : Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        if !isUser { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border) }
                        if item.pending {
                            RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                HStack(spacing: 4) {
                    if item.pending {
                        Image(systemName: "clock")
                        Text("Queued — the agent will read it at the next step")
                    }
                    if let at = item.at { Text(Format.clock(at)).monospacedDigit() }
                }
                .font(.system(size: 10))
                .foregroundStyle(item.pending ? Theme.accent : Theme.muted)
            }
            if !isUser { Spacer(minLength: 60) }
        }
    }

    /// Markdown'ın satır içi kısmı (kalın, kod, bağlantı); satır sonları korunur.
    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// "12 adım" diye kapanan, tıklayınca açılan araç adımları.
private struct ToolGroup: View {
    let items: [ChatItem]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                    Text(summary)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    if items.contains(where: { if case .tool(_, _, true) = $0.kind { true } else { false } }) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.warning)
                    }
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { item in
                        if case .tool(let name, let summary, let failed) = item.kind {
                            let event = ToolEvent(id: item.id, name: name, summary: summary, at: item.at ?? .now)
                            HStack(spacing: 6) {
                                Image(systemName: ShiftScanner.activity(forTool: event).symbol)
                                    .font(.system(size: 10))
                                    .frame(width: 14)
                                Text(event.displayName)
                                    .font(.system(size: 11, weight: .medium))
                                Text(summary)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(failed ? Theme.warning : Theme.textSecondary)
                        }
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let names = items.compactMap { item -> String? in
            if case .tool(let name, _, _) = item.kind { return name.split(separator: "__").last.map(String.init) ?? name }
            return nil
        }
        var counts: [(String, Int)] = []
        for n in names {
            if let i = counts.firstIndex(where: { $0.0 == n }) { counts[i].1 += 1 } else { counts.append((n, 1)) }
        }
        let detail = counts.prefix(4).map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: " · ")
        return String(localized: "\(items.count) steps") + " — " + detail
    }
}
