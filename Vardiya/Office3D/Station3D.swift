import AppKit
import RealityKit

/// Tek bir çalışma masası: masa, sandalye, monitör, klavye, lamba.
/// Monitörün ekranı ajanın durumuna göre parlar, gece çalışanların lambası yanar.
@MainActor
final class Station3D {
    static let deskHeight: Float = 0.384

    let entity = Entity()
    let deskTop: SIMD3<Float>
    private let screen: ModelEntity
    private let screenLight = PointLight()
    private let lampLight = PointLight()
    private var occupant: Activity?
    private var lastKey = ""

    init(assets: Assets3D, at center: SIMD3<Float>) {
        entity.position = center
        deskTop = center + [0, Self.deskHeight, 0]

        // Kenney masasının bir yanı kapalı ön panel; bacak boşluğu çalışana (z−) baksın diye 180° çeviriyoruz.
        let desk = assets.prop("desk")
        desk.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        entity.addChild(desk)

        // Sandalye masanın arkasında; Kenney modeli zaten +z'ye (masaya) bakıyor.
        let chair = assets.prop("chairDesk")
        chair.position = [0, 0, -0.52]
        entity.addChild(chair)

        // Monitör masanın uzak (z+) kenarında, ekranı karaktere (z−) dönük
        let monitor = assets.prop("computerScreen")
        monitor.position = [0.02, Self.deskHeight, 0.12]
        monitor.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        entity.addChild(monitor)

        let keyboard = assets.prop("computerKeyboard")
        keyboard.position = [0, Self.deskHeight, -0.1]
        keyboard.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        entity.addChild(keyboard)

        // Karakter +z'ye baktığı için onun sağ eli −x tarafında: fare klavyenin sağına.
        let mouse = assets.prop("computerMouse")
        mouse.position = [-0.22, Self.deskHeight, -0.1]
        entity.addChild(mouse)

        let lamp = assets.prop("lampSquareTable")
        lamp.position = [0.27, Self.deskHeight, 0.08]
        entity.addChild(lamp)

        // Ekranın parlayan yüzü. Kenney monitörünün paneli 39×25 cm, tabanın 17 cm üstünde ve
        // ~7° geriye yatık (ölçüm: scripts/build_assets.py ile aynı GLB). Monitörü 180° çevirdiğimiz
        // için panelin ön yüzü masada z≈0.115'e düşüyor; parlayan yüzeyi onun 5 mm önüne, aynı eğimle koyuyoruz.
        // Panelin neredeyse tamamı: 39×25 cm panelden ince bir çerçeve payı kalıyor.
        screen = ModelEntity(mesh: .generatePlane(width: 0.375, height: 0.236, cornerRadius: 0.006), materials: [UnlitMaterial(color: .black)])
        screen.position = [0.02, Self.deskHeight + 0.17, 0.104]
        screen.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0]) * simd_quatf(angle: -0.13, axis: [1, 0, 0])
        entity.addChild(screen)

        // Ekran ışığı karakterin yüzüne vursun.
        screenLight.light.intensity = 0
        screenLight.light.attenuationRadius = 0.9
        screenLight.position = [0.02, Self.deskHeight + 0.2, -0.05]
        entity.addChild(screenLight)

        lampLight.light.color = NSColor(srgbRed: 1, green: 0.82, blue: 0.55, alpha: 1)
        lampLight.light.intensity = 0
        lampLight.light.attenuationRadius = 1.6
        lampLight.position = [0.27, Self.deskHeight + 0.32, 0.02]
        entity.addChild(lampLight)
    }

    func setOccupant(_ activity: Activity?) {
        occupant = activity
    }

    func tick(time: Float, daylight: Float) {
        let a = occupant
        let busy = a?.isBusy ?? false
        let needsYou = a?.needsYou ?? false

        // Ekran: yazarken/komut çalışırken kayan kod, okurken belge, düşünürken yanıp sönen imleç,
        // sizi beklerken turuncu nabız, boştayken loş, masa boşsa kapalı.
        let glow: Float
        var reel: ScreenTextures.Reel?
        var fps: Float = 0
        var solid: NSColor?
        switch a {
        case nil:
            solid = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1); glow = 0
        case .some(let act) where act.needsYou:
            let pulse = 0.75 + 0.25 * sin(time * 5)
            solid = NSColor(srgbRed: 1, green: 0.62 * CGFloat(pulse), blue: 0.2, alpha: 1); glow = 260
        case .readingDocs, .writingDocs, .webSearching:
            reel = .document; fps = 3; glow = 300
        case .viewing, .capturing:
            reel = .image; fps = 2; glow = 300
        case .thinking:
            reel = .cursor; fps = 4; glow = 140
        case .reading, .searching:
            // Kod inceliyor: kod ekranı ama yavaş kayıyor
            reel = .code; fps = 2; glow = 240
        case .some(let act) where act.isBusy:
            reel = .code; fps = 7; glow = 260
        default:
            solid = NSColor(srgbRed: 0.16, green: 0.2, blue: 0.27, alpha: 1); glow = 50
        }
        if let reel {
            let frames = ScreenTextures.frames(reel)
            // Masalar aynı anda aynı kareyi göstermesin diye konuma göre faz kaydırıyoruz.
            let phase = Int(abs(entity.position.x * 7 + entity.position.z * 13))
            let index = frames.isEmpty ? 0 : (Int(time * fps) + phase) % frames.count
            let key = "\(reel)-\(index)"
            if key != lastKey, !frames.isEmpty {
                lastKey = key
                var m = UnlitMaterial()
                m.color = .init(tint: .white, texture: .init(frames[index]))
                screen.model?.materials = [m]
                screenLight.light.color = reel == .document ? .white : NSColor(srgbRed: 0.3, green: 0.9, blue: 0.5, alpha: 1)
            }
        } else if let solid {
            let key = "\(solid.redComponent.rounded2)-\(solid.greenComponent.rounded2)-\(solid.blueComponent.rounded2)"
            if key != lastKey {
                lastKey = key
                screen.model?.materials = [UnlitMaterial(color: solid)]
                screenLight.light.color = solid
            }
        }
        // Ekran ışığı karanlıkta daha belirgin
        screenLight.light.intensity = glow * (1.6 - daylight)

        // Gece vardiyası: yalnızca çalışan masaların lambası yanar.
        let night = 1 - daylight
        let lampOn: Float = busy || needsYou ? 1 : 0
        let target = lampOn * night * 900
        lampLight.light.intensity += (target - lampLight.light.intensity) * 0.08
    }
}

private extension CGFloat {
    var rounded2: Int { Int((self * 50).rounded()) }
}

/// Bir ajanın ofisteki yeri.
struct Home3D: Equatable {
    var room: Int
    var slot: Int
    var seat: SIMD3<Float>
    var desk: SIMD3<Float>
}

// MARK: - Zarf

/// Mesaj zarfı: kapıdan masaya (istek), masadan kapıya (yanıt) ya da masadan masaya (iş verme)
/// yay çizerek uçar, arkasında ışıklı noktalar bırakır.
@MainActor
final class Envelope3D {
    enum Kind { case prompt, reply, delegate }

    let entity = Entity()
    private let from: SIMD3<Float>
    private let to: SIMD3<Float>
    private let duration: Float
    private var t: Float = 0
    private var trailClock: Float = 0
    private var trail: [(entity: ModelEntity, age: Float)] = []
    private let color: NSColor
    private let onArrive: () -> Void
    private var arrived = false

    var isFinished: Bool { arrived && trail.isEmpty }

    init(from: SIMD3<Float>, to: SIMD3<Float>, kind: Kind, onArrive: @escaping () -> Void) {
        self.from = from
        self.to = to
        self.onArrive = onArrive
        duration = max(1.0, min(2.4, simd_distance(from, to) / 3.2))
        switch kind {
        case .prompt: color = NSColor(Theme.accent)
        case .reply: color = NSColor(Theme.success)
        case .delegate: color = NSColor(srgbRed: 0.55, green: 0.45, blue: 1, alpha: 1)
        }

        var paper = PhysicallyBasedMaterial()
        paper.baseColor = .init(tint: .white)
        paper.emissiveColor = .init(color: .white)
        paper.emissiveIntensity = 0.4
        let body = ModelEntity(mesh: .generateBox(width: 0.16, height: 0.012, depth: 0.11, cornerRadius: 0.004), materials: [paper])
        var flapMat = PhysicallyBasedMaterial()
        flapMat.baseColor = .init(tint: color)
        flapMat.emissiveColor = .init(color: color)
        flapMat.emissiveIntensity = 1.2
        let flap = ModelEntity(mesh: .generateBox(width: 0.1, height: 0.004, depth: 0.06, cornerRadius: 0.002), materials: [flapMat])
        flap.position = [0, 0.008, -0.012]
        flap.orientation = simd_quatf(angle: .pi / 4, axis: [0, 1, 0])
        body.addChild(flap)
        entity.addChild(body)

        let glow = PointLight()
        glow.light.color = color
        glow.light.intensity = 900
        glow.light.attenuationRadius = 0.7
        entity.addChild(glow)
        entity.position = from
    }

    func tick(dt: Float, parent: Entity) {
        if !arrived {
            t += dt / duration
            let k = min(1, t)
            let e = k * k * (3 - 2 * k)
            var p = from + (to - from) * e
            p.y += sin(Float.pi * e) * (0.9 + simd_distance(from, to) * 0.08)
            entity.position = p
            entity.orientation = simd_quatf(angle: Float(e) * .pi * 2 + atan2(to.x - from.x, to.z - from.z), axis: [0, 1, 0])

            trailClock += dt
            if trailClock > 0.035 {
                trailClock = 0
                var m = UnlitMaterial(color: color)
                m.blending = .transparent(opacity: 0.85)
                let dot = ModelEntity(mesh: .generateSphere(radius: 0.022), materials: [m])
                dot.position = p
                parent.addChild(dot)
                trail.append((dot, 0))
            }
            if k >= 1 {
                arrived = true
                entity.isEnabled = false
                onArrive()
            }
        }
        // İz noktaları küçülüp kaybolur.
        for i in trail.indices.reversed() {
            trail[i].age += dt
            let life: Float = 0.9
            let f = max(0, 1 - trail[i].age / life)
            trail[i].entity.scale = .init(repeating: 0.3 + 0.7 * f)
            trail[i].entity.components.set(OpacityComponent(opacity: f))
            if trail[i].age > life {
                trail[i].entity.removeFromParent()
                trail.remove(at: i)
            }
        }
    }
}
