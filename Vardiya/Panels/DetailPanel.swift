import SwiftUI

/// Sağ üst: seçili çalışanın kim olduğu, ne yaptığı ve son işlemleri.
struct DetailPanel: View {
    @Environment(ShiftStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let worker = store.selectedWorker, let shift = store.selectedShift {
                content(worker, shift: shift)
            } else {
                Text("Pick someone in the office")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private func content(_ worker: Worker, shift: Shift) -> some View {
        let a = worker.activity
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: a.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(a.tint)
                .frame(width: 34, height: 34)
                .background(a.softTint, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(worker.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(headline(worker))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            StatusPill(activity: a)
        }

        VStack(alignment: .leading, spacing: 7) {
            if case .subagent = worker.kind {
                Row(label: String(localized: "Task"), value: worker.subtitle)
            } else if let title = shift.title {
                Row(label: String(localized: "Topic"), value: title)
            }
            Row(label: String(localized: "Project"), value: shift.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            if let model = Format.model(worker.model) {
                Row(label: String(localized: "Model"), value: model)
            }
            if let started = worker.startedAt {
                Row(label: String(localized: "Started"), value: String(localized: "\(Format.clock(started)) (\(Format.elapsed(since: started)) ago)"))
            }
            Row(label: String(localized: "Context"), value: String(localized: "\(Format.tokens(worker.contextTokens)) tokens"))
            Row(label: String(localized: "Output"), value: String(localized: "\(Format.tokens(worker.outputTokens)) tokens · \(worker.toolCount) tool calls"))
        }

        if worker.kind == .main {
            ChatOpener(shift: shift)
        }

        if worker.lastUserText != nil || worker.lastReplyText != nil {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let text = worker.lastUserText {
                    Exchange(symbol: "envelope.fill", tint: Theme.accent, title: String(localized: "Your last message"), text: text, at: worker.lastUserAt)
                }
                if let text = worker.lastReplyText {
                    Exchange(symbol: "text.bubble.fill", tint: Theme.success, title: String(localized: "Last reply"), text: text, at: worker.lastReplyAt)
                }
            }
        }

        if !worker.recent.isEmpty {
            Divider()
            Text("Recent work")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(worker.recent.prefix(6)) { event in
                    RecentRow(event: event)
                }
            }
        }
    }

    private func headline(_ worker: Worker) -> String {
        let a = worker.activity
        if let detail = a.detail { return detail }
        switch a {
        case .idle: return String(localized: "Finished and waiting for your next message")
        case .thinking: return String(localized: "Thinking about the next step")
        case .done: return String(localized: "Handed the result back")
        case .asking: return String(localized: "Has a question for you")
        default: return worker.subtitle
        }
    }

    /// Son mesaj / son yanıt satırı.
    private struct Exchange: View {
        let symbol: String
        let tint: Color
        let title: String
        let text: String
        let at: Date?

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                    .frame(width: 14)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if let at {
                            Text(Format.clock(at))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private struct Row: View {
        let label: String
        let value: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 70, alignment: .leading)
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private struct RecentRow: View {
        let event: ToolEvent

        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: ShiftScanner.activity(forTool: event).symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(event.failed ? Theme.warning : Theme.textSecondary)
                    .frame(width: 14)
                Text(event.summary.isEmpty ? event.displayName : event.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if event.finishedAt == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(Format.clock(event.at))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

struct StatusPill: View {
    let activity: Activity

    var body: some View {
        Text(activity.label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(activity.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(activity.softTint, in: RoundedRectangle(cornerRadius: 6))
            .lineLimit(1)
            .fixedSize()
    }
}

/// Panelde mesaj kutusu görünümünde bir düğme: tıklayınca sohbet penceresi açılır,
/// konuşmanın tamamı orada görünür ve mesaj oradan yazılır.
struct ChatOpener: View {
    let shift: Shift
    @Environment(\.openWindow) private var openWindow
    @State private var feedback: String?
    @State private var confirmClose = false
    @State private var closing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                openWindow(id: "chat", value: shift.id)
            } label: {
                HStack(alignment: .top) {
                    Text("Message \(shift.project)…")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                .background(Theme.mutedSoft, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Open the chat with this session"))
            HStack {
                if let feedback {
                    Label(feedback, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                        .lineLimit(2)
                }
                Spacer()
                Button(role: .destructive) {
                    confirmClose = true
                } label: {
                    Label(closing ? String(localized: "Closing…") : String(localized: "End session"), systemImage: "xmark.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.link)
                .tint(Theme.warning)
                .disabled(closing)
                Button {
                    if case .failure(let f) = TerminalBridge.focus(pid: shift.pid) { feedback = f.message }
                } label: {
                    Label("Open terminal", systemImage: "terminal").font(.system(size: 11))
                }
                .buttonStyle(.link)
            }
        }
        .confirmationDialog(String(localized: "End the \(shift.project) session?"), isPresented: $confirmClose) {
            Button(String(localized: "End session"), role: .destructive) {
                closing = true
                TerminalBridge.close(pid: shift.pid) { result in
                    closing = false
                    if case .failure(let f) = result { feedback = f.message }
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            if shift.workers.contains(where: { $0.activity.isBusy }) {
                Text("This agent is working right now; its current task will stop. Claude gets /exit and the terminal tab closes.")
            } else {
                Text("Claude gets /exit and the terminal tab closes. The conversation stays in Claude's history.")
            }
        }
    }
}

/// Mesaj yazma kutusu: gönderince metin oturumun terminal sekmesine gider.
/// Dosya ya da görsel sürükleyip bırakınca yolu kutuya yazılır (iTerm2'deki gibi).
struct MessageComposer: View {
    let shift: Shift
    var autofocus = false
    @State private var text = ""
    @State private var feedback: (text: String, isError: Bool)?
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                TextField(String(localized: "Message \(shift.project)…"), text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(3...10)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.leading, 10)
                    .padding(.trailing, 44)
                    .padding(.vertical, 9)
                    .frame(minHeight: 72, alignment: .topLeading)
                    .background(Theme.mutedSoft, in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(dropTargeted ? Theme.accent : (focused ? Theme.accent : Theme.border),
                                          style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: dropTargeted ? [5, 4] : []))
                    }
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(text.isEmpty ? Theme.muted : Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(Text("Send to the session's terminal"))
                .padding(6)
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: handleDrop)

            HStack {
                if let feedback {
                    Label(feedback.text, systemImage: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(feedback.isError ? Theme.warning : Theme.success)
                        .lineLimit(2)
                } else {
                    Text("Drop a file or image to add its path")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button {
                    if case .failure(let f) = TerminalBridge.focus(pid: shift.pid) { feedback = (f.message, true) }
                } label: {
                    Label("Open terminal", systemImage: "terminal").font(.system(size: 11))
                }
                .buttonStyle(.link)
            }
        }
        .onAppear { if autofocus { focused = true } }
        .onChange(of: shift.id) { _, _ in text = ""; feedback = nil }
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        // Metni hemen kutudan al; terminal gönderimi arka planda bir-iki saniye sürer.
        text = ""
        feedback = (String(localized: "Sending…"), false)
        TerminalBridge.send(message, toPID: shift.pid) { result in
            switch result {
            case .success:
                feedback = (String(localized: "Sent. The envelope is on its way."), false)
            case .failure(let f):
                text = message
                feedback = (f.message, true)
            }
        }
    }

    /// Bırakılan dosyaların yolunu, terminaldeki gibi boşlukları kaçışlayarak ekler.
    /// Dosyası olmayan görseller (tarayıcıdan sürüklenen) geçici bir PNG'ye kaydedilir.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in insert(path: url.path) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage, let path = Self.saveTemporary(image) else { return }
                    Task { @MainActor in insert(path: path) }
                }
            }
        }
        return handled
    }

    private func insert(path: String) {
        let escaped = path.replacingOccurrences(of: " ", with: "\\ ")
        if !text.isEmpty, !text.hasSuffix(" ") { text += " " }
        text += escaped + " "
        focused = true
    }

    nonisolated private static func saveTemporary(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appending(path: "Vardiya", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "drop-\(Int(Date.now.timeIntervalSince1970)).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return url.path
    }
}

/// Sağ alt: vardiyadaki tüm oturumlar; referanstaki "iş kuyruğu" kartı.
struct ShiftList: View {
    @Environment(ShiftStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("On shift")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(store.busyCount) of \(store.shifts.flatMap(\.workers).count) working")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            let total = max(1, store.shifts.flatMap(\.workers).count)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.accentSoft)
                    Capsule().fill(Theme.accent)
                        .frame(width: geo.size.width * CGFloat(store.busyCount) / CGFloat(total))
                }
            }
            .frame(height: 5)
            .animation(.snappy, value: store.busyCount)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.shifts) { shift in
                        ShiftRow(shift: shift, isSelected: store.selectedShift?.id == shift.id)
                            .onTapGesture { store.selectedWorkerID = shift.main.id }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private struct ShiftRow: View {
        let shift: Shift
        let isSelected: Bool

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shift.project)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let title = shift.title {
                        Text(title)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                if !shift.subagents.isEmpty {
                    Text("+\(shift.subagents.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                StatusPill(activity: shift.main.activity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isSelected ? Theme.accentSoft.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
    }
}
