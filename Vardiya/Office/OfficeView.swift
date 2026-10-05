import SwiftUI

/// Ofis sahnesi + üstündeki tıklanabilir durum balonları ve token rozetleri.
struct OfficeView: View {
    @Environment(ShiftStore.self) private var store

    var body: some View {
        let rooms = Room.group(store.shifts)
        let layout = OfficeLayout(count: rooms.count)
        let placed = layout.place(rooms)

        GeometryReader { geo in
            let iso = layout.projection(in: geo.size, inset: EdgeInsets(top: 56, leading: 24, bottom: 24, trailing: 24))
            ZStack(alignment: .topLeading) {
                OfficeCanvas(layout: layout, placed: placed, selectedID: store.selectedWorkerID, iso: iso)
                    .contentShape(Rectangle())
                    .onTapGesture { location in select(at: location, placed: placed, iso: iso) }

                ForEach(placed) { p in
                    TokenChip(worker: p.worker)
                        .position(iso.p(p.seat.x + 0.2, p.seat.y + 0.95))
                    StatusBubble(worker: p.worker, isSelected: p.id == store.selectedWorkerID)
                        .onTapGesture { store.selectedWorkerID = p.id }
                        .position(bubblePoint(p, iso: iso))
                }
            }
        }
        .overlay {
            if store.shifts.isEmpty {
                EmptyOffice()
            }
        }
    }

    private func bubblePoint(_ p: PlacedWorker, iso: Iso) -> CGPoint {
        var point = iso.p(p.seat.x, p.seat.y - 0.62, 1.32)
        point.y -= 14
        return point
    }

    /// Karakterin ya da masanın üstüne tıklanınca onu seç.
    private func select(at location: CGPoint, placed: [PlacedWorker], iso: Iso) {
        let hit = placed.min { a, b in
            distance(location, iso.p(a.seat.x, a.seat.y - 0.3, 0.6)) < distance(location, iso.p(b.seat.x, b.seat.y - 0.3, 0.6))
        }
        if let hit, distance(location, iso.p(hit.seat.x, hit.seat.y - 0.3, 0.6)) < iso.scale * 1.1 {
            store.selectedWorkerID = hit.id
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Karakterin başının üstündeki "ad · ikon · durum" balonu.
struct StatusBubble: View {
    let worker: Worker
    let isSelected: Bool

    var body: some View {
        let a = worker.activity
        HStack(spacing: 5) {
            Text(worker.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Image(systemName: a.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(a.tint)
            Circle().fill(a.tint).frame(width: 5, height: 5)
            Text(a.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(a.tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? Theme.accent : Theme.border, lineWidth: isSelected ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .fixedSize()
        .contentShape(Rectangle())
        .animation(.snappy, value: a)
    }
}

/// Masanın önündeki token rozeti; referanstaki "ücret" rozetinin karşılığı.
struct TokenChip: View {
    let worker: Worker

    var body: some View {
        let done = worker.activity == .done
        HStack(spacing: 4) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.hexagongrid")
                .font(.system(size: 9, weight: .semibold))
            Text("\(Format.tokens(worker.outputTokens)) tokens")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(done ? Theme.success : Theme.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border) }
        .fixedSize()
        .allowsHitTesting(false)
    }
}

struct EmptyOffice: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 28))
                .foregroundStyle(Theme.muted)
            Text("Nobody is on shift")
                .font(.headline)
                .foregroundStyle(Theme.text)
            Text("Open Claude Code in a terminal and the desk fills up on its own.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(24)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border) }
    }
}
