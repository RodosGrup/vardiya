import Foundation
import simd

/// 3D ofisin planı (metre, Y yukarı). Sol şeritte kahve köşesi ve lavabo, arka duvarda
/// pencereler ve kapı; sağda her proje için 2×3 masalık bir oda.
///
///   z=0 ┌──────── arka duvar (pencereler, kapı) ────────┐
///       │ kahve  │  oda 1         │  oda 2              │
///       │ köşesi │  [masa][masa]  │  [masa][masa]       │
///       │────────│  [masa][masa]  │  …                  │
///       │ lavabo │  [masa][masa]  │                     │
///       └────────┴────────────────┴─────────────────────┘
struct OfficeLayout3D {
    static let amenityWidth: Float = 1.8
    static let roomGap: Float = 0.5
    static let margin: Float = 0.5
    static let maxPerRoom = 6
    /// Sağdaki kantin şeridi: yemek masası ve sebil.
    static let canteenWidth: Float = 2.1

    let roomCount: Int
    let cols: Int
    let rows: Int
    /// En kalabalık odadaki kişi sayısı; bütün odalar bu kadar masaya göre boyutlanır.
    let capacity: Int

    init(roomCount: Int, capacity: Int = 1) {
        self.roomCount = max(roomCount, 1)
        self.capacity = min(max(capacity, 1), Self.maxPerRoom)
        cols = self.roomCount <= 2 ? self.roomCount : (self.roomCount <= 4 ? 2 : 3)
        rows = Int((Float(self.roomCount) / Float(cols)).rounded(.up))
    }

    /// Oda içindeki masa sütunu ve sırası: tek kişilik odada tek sütun, sonra 2 sütun.
    var deskCols: Int { capacity > 1 ? 2 : 1 }
    var deskRows: Int { Int((Float(capacity) / Float(deskCols)).rounded(.up)) }
    var roomWidth: Float { deskCols == 1 ? 1.75 : 2.9 }
    var roomDepth: Float { 0.55 + Float(deskRows) * 1.3 }

    /// Oda içindeki masa merkezi. Çalışan masanın arkasında (z−) oturup +z'ye bakar.
    func station(_ slot: Int) -> SIMD2<Float> {
        let c = slot % deskCols, r = slot / deskCols
        return [0.85 + Float(c) * 1.2, 1.05 + Float(r) * 1.3]
    }

    var width: Float {
        roomsEndX + Self.margin + Self.canteenWidth
    }

    var depth: Float {
        max(Self.margin + Float(rows) * roomDepth + Float(rows - 1) * Self.roomGap + Self.margin, 4.6)
    }

    var center: SIMD3<Float> { [width / 2, 0, depth / 2] }

    /// Odaların bittiği x; kantin bundan sonra başlar.
    var roomsEndX: Float {
        Self.amenityWidth + Self.margin + Float(cols) * roomWidth + Float(cols - 1) * Self.roomGap
    }

    /// İki ana koridor: sol (kahve/lavabo/kapı tarafı) ve sağ (kantin tarafı).
    var leftHubX: Float { Self.amenityWidth + 0.25 }
    var rightHubX: Float { roomsEndX + Self.margin / 2 }

    // Kantin
    var canteenX: Float { roomsEndX + Self.margin }
    var diningTable: SIMD3<Float> { [canteenX + Self.canteenWidth / 2, 0, max(2.0, depth / 2 - 0.2)] }
    /// Masanın çevresindeki dört sandalye: (konum, yüz yönü)
    var diningSeats: [(SIMD3<Float>, Float)] {
        let t = diningTable
        return [(t + [0, 0, -0.62], 0), (t + [0.58, 0, 0], -.pi / 2), (t + [0, 0, 0.62], .pi), (t + [-0.58, 0, 0], .pi / 2)]
    }
    var waterCooler: SIMD3<Float> { [canteenX + Self.canteenWidth - 0.35, 0, 0.3] }
    var waterSpot: SIMD3<Float> { waterCooler + [0, 0, 0.5] }

    func roomOrigin(_ index: Int) -> SIMD2<Float> {
        let col = Float(index % cols), row = Float(index / cols)
        return [Self.amenityWidth + Self.margin + col * (roomWidth + Self.roomGap),
                Self.margin + row * (roomDepth + Self.roomGap)]
    }

    func desk(room: Int, slot: Int) -> SIMD3<Float> {
        let o = roomOrigin(room), s = station(slot)
        return [o.x + s.x, 0, o.y + s.y]
    }

    /// Çalışanın oturduğu nokta: masanın arkası.
    func seat(room: Int, slot: Int) -> SIMD3<Float> {
        desk(room: room, slot: slot) + [0, 0, -0.5]
    }

    // MARK: Ortak alanlar

    /// Kapı arka duvarda, kahve köşesinin hemen sağında; zarflar ve yeni gelenler buradan girer.
    var door: SIMD3<Float> { [Self.amenityWidth + 0.7, 0, 0.05] }
    var coffeeSpot: SIMD3<Float> { [0.75, 0, 1.15] }
    var coffeeMachine: SIMD3<Float> { [0.75, 0, 0.35] }
    /// Lavabo kabini sol alt köşede: x 0…boothWidth, z depth−boothDepth…depth; kapısı sağ duvarda.
    static let boothWidth: Float = 1.3
    static let boothDepth: Float = 1.2
    var boothDoorZ: Float { depth - 0.6 }
    var toiletSpot: SIMD3<Float> { [0.5, 0, depth - 0.55] }
    /// Kapının dışındaki bekleme noktası
    var toiletDoor: SIMD3<Float> { [Self.boothWidth + 0.3, 0, boothDoorZ] }
    var sinkSpot: SIMD3<Float> { [1.0, 0, depth - Self.boothDepth + 0.5] }

    func inBooth(_ p: SIMD3<Float>) -> Bool {
        p.x < Self.boothWidth && p.z > depth - Self.boothDepth
    }
    var sofaSpot: SIMD3<Float> { [0.9, 0, depth / 2 + 0.2] }

    /// Odanın önündeki koridor; yürüyüşler masaların arasından değil buradan geçer.
    func aisleZ(room: Int) -> Float {
        roomOrigin(room).y - Self.roomGap / 2
    }
}

/// Ofisin saati (gün/gece, öğle arası). Gerçek saat; DEBUG'da `-vardiyaHour 12.5` ile değiştirilebilir.
func officeHour(_ date: Date = .now) -> Float {
    #if DEBUG
    if UserDefaults.standard.object(forKey: "vardiyaHour") != nil {
        return Float(UserDefaults.standard.double(forKey: "vardiyaHour"))
    }
    #endif
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return Float(c.hour ?? 12) + Float(c.minute ?? 0) / 60
}
