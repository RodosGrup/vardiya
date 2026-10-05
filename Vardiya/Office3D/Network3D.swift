import AppKit
import RealityKit

/// Sunucu kabini: koyu gövde, önünde sıra sıra LED. Trafik arttıkça LED'ler hızlanır, kabin hafifçe parlar.
@MainActor
final class ServerRack {
    let entity = Entity()
    /// Bağlantıların kabine girdiği nokta (üst ön)
    let port: SIMD3<Float>
    private var leds: [ModelEntity] = []
    private let glow = PointLight()
    private var lastStep = -1

    init(at p: SIMD3<Float>) {
        entity.position = p
        port = p + [0, 0.95, 0.12]

        var body = PhysicallyBasedMaterial()
        body.baseColor = .init(tint: NSColor(srgbRed: 0.14, green: 0.15, blue: 0.18, alpha: 1))
        body.roughness = 0.45
        body.metallic = 0.3
        let cabinet = ModelEntity(mesh: .generateBox(width: 0.34, height: 1.0, depth: 0.3, cornerRadius: 0.015), materials: [body])
        cabinet.position = [0, 0.5, 0]
        entity.addChild(cabinet)

        // Raf bölmeleri ve LED'ler
        var slot = PhysicallyBasedMaterial()
        slot.baseColor = .init(tint: NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1))
        for row in 0..<7 {
            let y = 0.14 + Float(row) * 0.12
            let shelf = ModelEntity(mesh: .generateBox(width: 0.3, height: 0.09, depth: 0.01, cornerRadius: 0.004), materials: [slot])
            shelf.position = [0, y, 0.151]
            entity.addChild(shelf)
            for col in 0..<4 {
                let led = ModelEntity(mesh: .generateBox(width: 0.018, height: 0.012, depth: 0.006), materials: [UnlitMaterial(color: .green)])
                led.position = [-0.11 + Float(col) * 0.035, y + 0.02, 0.158]
                entity.addChild(led)
                leds.append(led)
            }
        }
        // Üstte anten: "internet" buradan çıkıyor
        let mast = ModelEntity(mesh: .generateCylinder(height: 0.14, radius: 0.006), materials: [body])
        mast.position = [0.1, 1.07, 0]
        entity.addChild(mast)

        glow.light.color = NSColor(srgbRed: 0.25, green: 0.95, blue: 0.45, alpha: 1)
        glow.light.intensity = 0
        glow.light.attenuationRadius = 1.4
        glow.position = [0, 0.7, 0.35]
        entity.addChild(glow)
        entity.components.set(GroundingShadowComponent(castsShadow: true))
    }

    func tick(time: Float, traffic: Int) {
        // Boştayken yavaş, trafikte hızlı yanıp sönme
        let rate: Float = traffic > 0 ? 9 : 1.5
        let step = Int(time * rate)
        glow.light.intensity += ((traffic > 0 ? 600 : 0) - glow.light.intensity) * 0.1
        guard step != lastStep else { return }
        lastStep = step
        let green = NSColor(srgbRed: 0.25, green: 0.95, blue: 0.45, alpha: 1)
        let cyan = NSColor(srgbRed: 0.3, green: 0.85, blue: 1, alpha: 1)
        let off = NSColor(srgbRed: 0.06, green: 0.12, blue: 0.08, alpha: 1)
        for (i, led) in leds.enumerated() {
            let n = sin(Double(i * 37 + step * 13) * 12.9898) * 43758.5453
            let r = n - floor(n)
            let on = traffic > 0 ? r > 0.35 : r > 0.75
            led.model?.materials = [UnlitMaterial(color: on ? (i % 5 == 0 ? cyan : green) : off)]
        }
    }
}

/// İki nokta arasında ışıklı bir yay ve üzerinde akan veri paketleri.
/// Bağlantı kapanınca paketler biter, yay sönerek kaybolur.
@MainActor
final class DataLink {
    enum Kind { case web, delegate }

    let entity = Entity()
    var isActive = true
    private let from: SIMD3<Float>
    private let to: SIMD3<Float>
    private let color: NSColor
    private var dots: [ModelEntity] = []
    private var packets: [(entity: ModelEntity, t: Float, forward: Bool)] = []
    private var spawnClock: Float = 0
    private var fade: Float = 0
    private static let dotCount = 34

    var isFinished: Bool { !isActive && fade <= 0.01 && packets.isEmpty }

    init(from: SIMD3<Float>, to: SIMD3<Float>, kind: Kind) {
        self.from = from
        self.to = to
        // Web: kabinin LED'leriyle aynı yeşil ("bağlı"); alt ajan: mor
        color = kind == .web ? NSColor(srgbRed: 0.2, green: 0.92, blue: 0.42, alpha: 1) : NSColor(srgbRed: 0.6, green: 0.45, blue: 1, alpha: 1)
        // Kesikli yay: küçük, yarı saydam noktalar
        for i in 0..<Self.dotCount {
            // Saydamlık OpacityComponent'ten gelir; malzemenin kendi opaklığı tam olmalı (çarpılıyorlar).
            var m = UnlitMaterial(color: color)
            m.blending = .transparent(opacity: 1.0)
            let dot = ModelEntity(mesh: .generateSphere(radius: 0.018), materials: [m])
            dot.position = point(at: Float(i) / Float(Self.dotCount - 1))
            entity.addChild(dot)
            dots.append(dot)
        }
    }

    private func point(at t: Float) -> SIMD3<Float> {
        var p = from + (to - from) * t
        p.y += sin(.pi * t) * (0.5 + simd_distance(from, to) * 0.12)
        return p
    }

    func tick(dt: Float, time: Float) {
        fade += ((isActive ? 1 : 0) - fade) * min(1, dt * 4)
        // Yay noktaları akıyormuş gibi sırayla parlar
        for (i, dot) in dots.enumerated() {
            let wave = 0.5 + 0.5 * sin(time * 6 - Float(i) * 0.6)
            dot.components.set(OpacityComponent(opacity: fade * (0.35 + 0.6 * wave)))
        }
        // Paketler: iki yöne de gidip gelir (istek ve yanıt)
        spawnClock += dt
        if isActive, spawnClock > 0.45 {
            spawnClock = 0
            let forward = Int(time * 10) % 3 != 0
            var m = UnlitMaterial(color: color)
            m.blending = .transparent(opacity: 0.95)
            let packet = ModelEntity(mesh: .generateBox(size: 0.05, cornerRadius: 0.01), materials: [m])
            entity.addChild(packet)
            packets.append((packet, 0, forward))
        }
        for i in packets.indices.reversed() {
            packets[i].t += dt * 0.9
            let t = packets[i].forward ? packets[i].t : 1 - packets[i].t
            packets[i].entity.position = point(at: min(1, max(0, t)))
            packets[i].entity.orientation = simd_quatf(angle: time * 4, axis: [0, 1, 0])
            if packets[i].t >= 1 {
                packets[i].entity.removeFromParent()
                packets.remove(at: i)
            }
        }
    }
}
