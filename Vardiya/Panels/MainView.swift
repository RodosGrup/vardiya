import SwiftUI

/// Ana pencere: solda ofis, sağda seçili çalışanın detayı ve vardiya listesi.
struct MainView: View {
    @Environment(ShiftStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header()
            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .topLeading) {
                    OfficeView()
                    SummaryChips()
                        .padding(14)
                    if let shift = store.selectedShift {
                        PipelineCard(shift: shift)
                            .padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
                .card()

                VStack(spacing: 14) {
                    DetailPanel()
                    ShiftList()
                }
                .frame(width: 320)
            }
        }
        .padding(18)
        .frame(minWidth: 1080, minHeight: 680)
        .background(Theme.window)
    }
}

private struct Header: View {
    @Environment(ShiftStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Office")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(Date.now.formatted(date: .complete, time: .omitted))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Sahnenin sol üstündeki özet rozetleri.
private struct SummaryChips: View {
    @Environment(ShiftStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Chip(symbol: "person.3", text: String(localized: "\(store.shifts.count) sessions"))
            Chip(symbol: "bolt.fill", text: String(localized: "\(store.busyCount) working"), tint: store.busyCount > 0 ? Theme.accent : nil)
            if store.needsYouCount > 0 {
                Chip(symbol: "hand.raised.fill", text: String(localized: "\(store.needsYouCount) need you"), tint: Theme.warning)
            }
            Chip(symbol: "circle.hexagongrid", text: String(localized: "\(Format.tokens(store.totalOutputTokens)) output tokens"))
            if let start = store.shiftStartedAt {
                Chip(symbol: "clock", text: String(localized: "Shift started \(Format.clock(start))"))
            }
        }
    }
}

struct Chip: View {
    let symbol: String
    let text: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(tint ?? Theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border) }
    }
}

/// Seçili oturumun iş hattı: istek → çalışma → teslim.
private struct PipelineCard: View {
    let shift: Shift

    var body: some View {
        let a = shift.main.activity
        let working = shift.workers.contains { $0.activity.isBusy }
        HStack(spacing: 0) {
            Stage(symbol: "text.bubble", title: String(localized: "Requests"),
                  value: "\(shift.promptCount)", state: .done)
            Connector()
            Stage(symbol: "hammer", title: String(localized: "Work"),
                  value: String(localized: "\(shift.workers.reduce(0) { $0 + $1.toolCount }) tool calls"),
                  state: working ? .active : .done)
            Connector()
            Stage(symbol: "shippingbox", title: String(localized: "Delivery"),
                  value: a.needsYou ? String(localized: "Waiting for you") : (working ? String(localized: "In progress") : String(localized: "Delivered")),
                  state: a.needsYou ? .attention : (working ? .pending : .done))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border) }
        .fixedSize()
    }

    enum StageState { case done, active, pending, attention }

    struct Stage: View {
        let symbol: String
        let title: String
        let value: String
        let state: StageState

        var tint: Color {
            switch state {
            case .done: Theme.accent
            case .active: Theme.accent
            case .pending: Theme.muted
            case .attention: Theme.warning
            }
        }

        var body: some View {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(state == .active ? tint : tint.opacity(0.12))
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state == .active ? .white : tint)
                }
                .frame(width: 30, height: 30)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                Text(value).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 92)
        }
    }

    struct Connector: View {
        var body: some View {
            Rectangle().fill(Theme.border).frame(width: 28, height: 1.5).offset(y: -18)
        }
    }
}

extension View {
    func card() -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border) }
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
