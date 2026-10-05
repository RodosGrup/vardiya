import SwiftUI

/// İzometrik izdüşüm: dünya birimi (x sağa-aşağı, y sola-aşağı, z yukarı) → ekran noktası.
struct Iso {
    var scale: CGFloat
    var origin: CGPoint

    static let cos30: CGFloat = 0.8660254
    static let sin30: CGFloat = 0.5

    func p(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint {
        CGPoint(
            x: origin.x + CGFloat(x - y) * Iso.cos30 * scale,
            y: origin.y + CGFloat(x + y) * Iso.sin30 * scale - CGFloat(z) * scale
        )
    }

    func quad(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Path {
        var path = Path()
        path.addLines([a, b, c, d])
        path.closeSubpath()
        return path
    }

    /// Kutunun izleyiciye bakan üç yüzü: üst, sol (y+) ve sağ (x+).
    func box(x: Double, y: Double, z: Double, w: Double, d: Double, h: Double) -> (top: Path, left: Path, right: Path) {
        let x1 = x + w, y1 = y + d, z1 = z + h
        let top = quad(p(x, y, z1), p(x1, y, z1), p(x1, y1, z1), p(x, y1, z1))
        let left = quad(p(x, y1, z1), p(x1, y1, z1), p(x1, y1, z), p(x, y1, z))
        let right = quad(p(x1, y, z1), p(x1, y1, z1), p(x1, y1, z), p(x1, y, z))
        return (top, left, right)
    }

    func fillBox(_ ctx: inout GraphicsContext, x: Double, y: Double, z: Double, w: Double, d: Double, h: Double,
                 top: Color, left: Color, right: Color, edge: Color? = nil) {
        let b = box(x: x, y: y, z: z, w: w, d: d, h: h)
        ctx.fill(b.left, with: .color(left))
        ctx.fill(b.right, with: .color(right))
        ctx.fill(b.top, with: .color(top))
        if let edge {
            for face in [b.top, b.left, b.right] {
                ctx.stroke(face, with: .color(edge), lineWidth: 0.6)
            }
        }
    }
}

/// Aynı klasörde çalışan oturumlar: ofiste tek bir oda.
struct Room: Identifiable {
    var id: String { cwd }
    let cwd: String
    let shifts: [Shift]

    static func group(_ shifts: [Shift]) -> [Room] {
        var order: [String] = []
        var byCwd: [String: [Shift]] = [:]
        for shift in shifts {
            if byCwd[shift.cwd] == nil { order.append(shift.cwd) }
            byCwd[shift.cwd, default: []].append(shift)
        }
        return order.map { Room(cwd: $0, shifts: byCwd[$0]!) }
    }
}

/// Ofis yerleşimi: her oda (proje) 4,6×4,6'lık bir alana sahip, içinde 2×3 masa.
struct OfficeLayout {
    static let podSize = 4.6
    /// Masa merkezleri; önce arka sıra, sonra öne doğru. Çalışan masanın arkasında (y−) oturur.
    static let seats: [(x: Double, y: Double)] = [
        (1.35, 1.2), (3.45, 1.2),
        (1.35, 2.8), (3.45, 2.8),
        (1.35, 4.4), (3.45, 4.4),
    ]

    let count: Int
    let cols: Int
    let rows: Int

    init(count: Int) {
        self.count = max(count, 1)
        cols = self.count <= 1 ? 1 : (self.count <= 4 ? 2 : 3)
        rows = Int((Double(self.count) / Double(cols)).rounded(.up))
    }

    var width: Double { Double(cols) * Self.podSize }
    var depth: Double { Double(rows) * Self.podSize }

    func podOrigin(_ index: Int) -> (x: Double, y: Double) {
        (Double(index % cols) * Self.podSize, Double(index / cols) * Self.podSize)
    }

    func seat(pod: Int, slot: Int) -> (x: Double, y: Double) {
        let o = podOrigin(pod)
        let s = Self.seats[slot]
        return (o.x + s.x, o.y + s.y)
    }

    /// Sahneyi verilen alana sığdıran izdüşüm.
    func projection(in size: CGSize, inset: EdgeInsets) -> Iso {
        let unit = Iso(scale: 1, origin: .zero)
        let pad = 0.6
        let corners = [
            unit.p(-pad, -pad, 2.0), unit.p(width + pad, -pad, 0),
            unit.p(-pad, depth + pad, 0), unit.p(width + pad, depth + pad, -0.3),
        ]
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        let availW = size.width - inset.leading - inset.trailing
        let availH = size.height - inset.top - inset.bottom
        let scale = max(8, min(availW / (maxX - minX), availH / (maxY - minY), 70))
        let usedW = (maxX - minX) * scale, usedH = (maxY - minY) * scale
        let origin = CGPoint(
            x: inset.leading + (availW - usedW) / 2 - minX * scale,
            y: inset.top + (availH - usedH) / 2 - minY * scale
        )
        return Iso(scale: scale, origin: origin)
    }
}

/// Sahnede çizilecek bir çalışan ve masasının konumu.
struct PlacedWorker: Identifiable {
    var id: String { worker.id }
    let worker: Worker
    let pod: Int
    let seat: (x: Double, y: Double)
    /// Alt ajanın bağlı olduğu ana çalışan; aktarım çizgisi ona çekilir.
    let parentID: String?

    var isSubagent: Bool { parentID != nil }
}

extension OfficeLayout {
    /// Odadaki herkesi masalara dağıtır: önce ana ajanlar, sonra alt ajanlar.
    /// Masa sayısından fazla kişi varsa en eski alt ajanlar sahnede gösterilmez.
    func place(_ rooms: [Room]) -> [PlacedWorker] {
        rooms.enumerated().flatMap { pod, room -> [PlacedWorker] in
            var people: [(Worker, String?)] = room.shifts.map { ($0.main, nil) }
            let subs = room.shifts.flatMap { shift in shift.subagents.map { ($0, Optional(shift.main.id)) } }
            people += subs.suffix(max(0, Self.seats.count - people.count))
            return people.prefix(Self.seats.count).enumerated().map { slot, entry in
                PlacedWorker(worker: entry.0, pod: pod, seat: seat(pod: pod, slot: slot), parentID: entry.1)
            }
        }
    }
}
