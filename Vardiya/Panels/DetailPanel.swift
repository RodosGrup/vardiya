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
