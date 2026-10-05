import AppKit
import RealityKit

/// Ofisin çevresi: çimen, bahçe, arka caddede yol ve sokak lambaları, karşıda şehir.
/// Yakın plan (kameranın baktığı ön ve sağ taraf) alçak tutuldu ki ofisi kapatmasın;
/// yüksek binalar arkada ve uzakta. Gece pencere ışıkları ve sokak lambaları yanar.
@MainActor
final class Environment3D {
    let entity = Entity()
    private var sky = ModelEntity()
    private var ground = ModelEntity()
    private var streetLights: [(light: PointLight, bulb: ModelEntity)] = []
    private var windows: [(plane: ModelEntity, seed: Float)] = []
    private var trees: [(entity: Entity, phase: Float)] = []
    private var lastNight: Float = -1

    /// Ofisten çıkan ajanın kaldırımda kaybolduğu nokta.
    static func sidewalk(for layout: OfficeLayout3D) -> SIMD3<Float> { [layout.door.x, 0, -3.3] }

    init(assets: Assets3D, layout: OfficeLayout3D) {
        let W = layout.width, D = layout.depth
        var rng = SeededRandom(seed: 7)

        func place(_ name: String, _ p: SIMD3<Float>, scale: Float, yaw: Float = 0) -> Entity {
            let e = assets.prop("env-" + name, scale: scale)
            e.position = p
            e.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            entity.addChild(e)
            return e
        }

        // Gökyüzü kubbesi: içinden bakıldığı için yüz ayıklaması kapalı; rengi saate göre değişir.
        var skyMat = UnlitMaterial(color: .white)
        skyMat.faceCulling = .none
        sky = ModelEntity(mesh: .generateSphere(radius: 95), materials: [skyMat])
        sky.position = layout.center
        entity.addChild(sky)

        // Çimen zemin
        var grass = PhysicallyBasedMaterial()
        grass.baseColor = .init(tint: NSColor(srgbRed: 0.42, green: 0.66, blue: 0.33, alpha: 1))
        grass.roughness = 0.95
        ground = ModelEntity(mesh: .generatePlane(width: 150, depth: 150), materials: [grass])
        ground.position = [layout.center.x, -0.012, layout.center.z]
        entity.addChild(ground)

        // Kaldırımlar ve cadde (arkada, z ekseninde −)
        let roadZ: Float = -5.6
        func strip(z: Float, depth: Float, color: NSColor, y: Float) {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: color)
            m.roughness = 0.9
            let s = ModelEntity(mesh: .generatePlane(width: 90, depth: depth), materials: [m])
            s.position = [W / 2, y, z]
            entity.addChild(s)
        }
        strip(z: -3.45, depth: 0.9, color: NSColor(srgbRed: 0.78, green: 0.78, blue: 0.76, alpha: 1), y: 0.004)
        strip(z: -7.75, depth: 0.9, color: NSColor(srgbRed: 0.78, green: 0.78, blue: 0.76, alpha: 1), y: 0.004)
        for i in -7...10 {
            _ = place("road-straight", [Float(i) * 3.5 + W / 2, 0.002, roadZ], scale: 3.5, yaw: .pi / 2)
        }

        // Kapıdan kaldırıma taş yol
        var z: Float = -0.45
        while z > -3.0 {
            _ = place("path_stone", [layout.door.x, 0.003, z], scale: 1.2, yaw: .pi / 2)
            z -= 0.7
        }

        // Sokak lambaları (kaldırım kenarında, yola dönük) ve park etmiş arabalar
        for i in 0..<6 {
            let x = -6 + Float(i) * 6
            let lamp = place("light-square", [x, 0, -3.85], scale: 4, yaw: .pi)
            let light = PointLight()
            light.light.color = NSColor(srgbRed: 1, green: 0.85, blue: 0.6, alpha: 1)
            light.light.intensity = 0
            light.light.attenuationRadius = 5
            light.position = [x, 2.3, -4.4]
            entity.addChild(light)
            let bulb = ModelEntity(mesh: .generateSphere(radius: 0.08), materials: [UnlitMaterial(color: .lightGray)])
            bulb.position = [x, 2.35, -4.45]
            entity.addChild(bulb)
            _ = lamp
            streetLights.append((light, bulb))
        }
        for (i, car) in ["sedan", "taxi", "suv", "van", "hatchback-sports"].enumerated() {
            let x = -4 + Float(i) * 7.3 + rng.next(-0.6, 0.6)
            _ = place(car, [x, 0.01, roadZ + (i % 2 == 0 ? 1.0 : -1.0)], scale: 0.85, yaw: i % 2 == 0 ? .pi / 2 : -.pi / 2)
        }

        // Caddenin karşısı: ofis binaları; pencerelerine gece ışığı
        let fronts = ["building-a", "building-c", "building-e", "building-g", "building-j", "building-l"]
        var x: Float = -14
        var k = 0
        while x < W + 18 {
            let name = fronts[k % fronts.count]
            let b = place(name, [x, 0, -10.6], scale: 3.5)
            addWindows(to: b, rng: &rng)
            x += b.visualBounds(relativeTo: nil).extents.x + 0.6
            k += 1
        }
        // Arkada gökdelenler
        let towers = ["building-skyscraper-a", "building-skyscraper-b", "building-skyscraper-c", "building-skyscraper-e"]
        for i in 0..<6 {
            let t = place(towers[i % towers.count], [-8 + Float(i) * 6.5 + rng.next(-1, 1), 0, -17 - rng.next(0, 3)], scale: 3.5)
            addWindows(to: t, rng: &rng)
        }
        // En uzakta şehir silueti
        let skyline = ["low-detail-building-a", "low-detail-building-c", "low-detail-building-e", "low-detail-building-h", "low-detail-building-k", "low-detail-building-wide-a"]
        for i in 0..<16 {
            let s = place(skyline[i % skyline.count], [-30 + Float(i) * 5 + rng.next(-1, 1), 0, -32 - rng.next(0, 6)], scale: 7)
            addWindows(to: s, rng: &rng, sparse: true)
        }

        // Sol taraf: ağaçlı müstakil evler
        let houses = ["building-type-a", "building-type-c", "building-type-f", "building-type-k", "building-type-p"]
        for i in 0..<5 {
            let hz = -1 + Float(i) * 4.2
            let house = place(houses[i], [-7.5, 0, hz], scale: 3.2, yaw: .pi / 2)
            addWindows(to: house, rng: &rng, sparse: true)
            trees.append((place("tree-large", [-4.8, 0, hz + 1.6], scale: 2.4), rng.next(0, 6)))
        }

        // Bahçe: arkada ve solda yüksek ağaçlar, önde ve sağda yalnızca alçak bitkiler
        let bigTrees = ["tree_oak", "tree_default", "tree_detailed", "tree_fat", "tree_cone"]
        // Arka sıradaki ağaçlar caddeyi kapatmasın: daha küçük ve arka duvardan biraz uzakta.
        for i in 0..<9 {
            let p: SIMD3<Float> = [-2.2 + Float(i) * 1.6 + rng.next(-0.3, 0.3), 0, -2.0 + rng.next(-0.3, 0.2)]
            if abs(p.x - layout.door.x) < 0.9 { continue }   // kapı yolunu kapatmasın
            trees.append((place(bigTrees[i % bigTrees.count], p, scale: 1.25), rng.next(0, 6)))
        }
        for i in 0..<5 {
            trees.append((place(bigTrees[(i + 2) % bigTrees.count], [-2.4 + rng.next(-0.3, 0.3), 0, Float(i) * 1.4 + 0.4], scale: 1.35), rng.next(0, 6)))
        }
        let low = ["plant_bush", "plant_bushDetailed", "plant_bushSmall", "flower_redA", "flower_yellowA", "flower_purpleA", "grass", "grass_large"]
        for i in 0..<34 {
            // Ön çimenlik (z > D) ve sağ kenar (x > W): alçak bitkiler
            let front = i % 2 == 0
            let p: SIMD3<Float> = front
                ? [rng.next(-1.5, W + 2), 0, D + rng.next(0.6, 4.5)]
                : [W + rng.next(0.6, 4), 0, rng.next(-1.5, D + 3)]
            // Kameraya yakın oldukları için küçük tutuluyor; büyük olunca ön planı kaplıyorlar.
            _ = place(low[i % low.count], p, scale: 1.0, yaw: rng.next(0, 6))
        }
        for i in 0..<4 {
            _ = place(i % 2 == 0 ? "rock_largeA" : "rock_smallA", [W + rng.next(1, 4), 0, D + rng.next(1, 4)], scale: 1.0, yaw: rng.next(0, 6))
        }
        // Uzak köşelerde birkaç ağaç daha (kamera yönünü kapatmayacak kadar uzakta)
        for i in 0..<6 {
            trees.append((place(bigTrees[i % bigTrees.count], [W + 7 + rng.next(0, 4), 0, -2 + Float(i) * 2.5], scale: 1.6), rng.next(0, 6)))
        }

        entity.components.set(GroundingShadowComponent(castsShadow: true))
    }

    /// Bina cephesine (ofise bakan +z yüzü) rastgele pencere ışıkları; gündüz görünmezler.
    private func addWindows(to building: Entity, rng: inout SeededRandom, sparse: Bool = false) {
        let b = building.visualBounds(relativeTo: nil)
        let cols = max(2, Int(b.extents.x / 0.7)), rows = max(2, Int(b.extents.y / 0.9))
        let count = sparse ? (cols * rows) / 5 : (cols * rows) / 3
        for _ in 0..<count {
            let c = Float(Int(rng.next(0, Float(cols)))), r = Float(Int(rng.next(1, Float(rows))))
            var m = UnlitMaterial(color: NSColor(srgbRed: 1, green: 0.86, blue: 0.55, alpha: 1))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            let w = ModelEntity(mesh: .generatePlane(width: 0.32, height: 0.36), materials: [m])
            w.position = [b.min.x + (c + 0.5) * (b.extents.x / Float(cols)), b.min.y + r * (b.extents.y / Float(rows)), b.max.z + 0.02]
            w.components.set(OpacityComponent(opacity: 0))
            entity.addChild(w)
            windows.append((w, rng.next(0, 1)))
        }
    }

    func tick(time: Float, daylight: Float, skyColor: NSColor) {
        // Ağaçlar rüzgârda hafifçe sallanır
        for (tree, phase) in trees {
            let sway = 0.025 * sin(time * 0.9 + phase) + 0.01 * sin(time * 2.3 + phase * 2)
            tree.orientation = simd_quatf(angle: sway, axis: [0, 0, 1]) * simd_quatf(angle: phase, axis: [0, 1, 0])
        }
        let night = 1 - daylight
        guard abs(night - lastNight) > 0.01 else { return }
        lastNight = night
        sky.model?.materials = [{ var m = UnlitMaterial(color: skyColor); m.faceCulling = .none; return m }()]
        for (light, bulb) in streetLights {
            light.light.intensity = night > 0.4 ? 5000 * night : 0
            bulb.model?.materials = [UnlitMaterial(color: night > 0.4 ? NSColor(srgbRed: 1, green: 0.88, blue: 0.6, alpha: 1) : .lightGray)]
        }
        // Gece pencerelerin bir kısmı yanar; eşik her pencere için farklı, hepsi birden yanıp sönmesin.
        for (w, seed) in windows {
            w.components.set(OpacityComponent(opacity: night > 0.3 && seed < night * 0.75 ? 0.95 : 0))
        }
    }
}

/// Her açılışta aynı çevre çıksın diye sabit tohumlu basit rastgele sayı üreteci.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }
    mutating func next(_ lo: Float, _ hi: Float) -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u = Float(state >> 40) / Float(1 << 24)
        return lo + (hi - lo) * u
    }
}
