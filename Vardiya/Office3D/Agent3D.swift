import Foundation
import RealityKit

/// Ofisteki tek bir karakter: gerçek durumu (Worker.activity) taklit eder, boş kaldığında
/// mola verir. Kural: çalışan bir ajan asla masasından uzakta görünmez; iş gelince koşarak döner.
@MainActor
final class Agent3D {
    private(set) var worker: Worker
    var home: Home3D
    weak var station: Station3D?
    var layout: OfficeLayout3D

    let entity = Entity()
    private let body: Entity
    private var joints: [String: Entity] = [:]
    private var rest: [String: SIMD3<Float>] = [:]
    private let animations: AnimationLibrary
    /// Kahve tezgâhında / kanepede / lavabo sırasında herkesin kendi yeri olsun diye;
    /// OfficeWorld her senkronda ajanlara 0, 1, 2… diye benzersiz sıra verir.
    var spotIndex: Int

    private enum Spot { case coffee, toilet, sofa, water, lunch, sink }
    private enum Mode {
        case seated
        case walking(path: [SIMD3<Float>], then: Arrival, speed: Float)
        case visiting(Spot, until: Float)
        case standing
    }
    private enum Arrival { case seat, spot(Spot), exit, rebel }

    private var mode: Mode = .seated
    private var yaw: Float = 0
    private var clipTime: Float = 0
    private var now: Float = 0
    private var nextBreakAt: Float
    private var receiveUntil: Float = -1
    /// Bugün öğle yemeği yedi mi; öğle arasında bir kez masaya oturur.
    private var lunchDay: Int = -1
    private var doneCheerUntil: Float = -1
    private(set) var isLeaving = false

    /// Masasında oturmuyor: yürüyor, molada ya da ayakta. Çarpışma önleme yalnızca bunlara uygulanır.
    /// Lavabo tek kişilik; içerideki ajanın kimliği.
    static var toiletOccupant: String?

    /// Mola yerlerindeki koltuk/tezgâh yerleri: "sofa#1" → ajan kimliği. Dolu yere kimse gitmez.
    private static var seatTaken: [String: String] = [:]
    private var reservedSeat: (spot: Spot, index: Int)?

    private static func capacity(of spot: Spot) -> Int {
        switch spot {
        case .coffee: 5
        case .sofa: 3
        case .lunch: 4
        case .water: 3
        case .toilet, .sink: 1
        }
    }

    /// Boş bir yer ayırır; hepsi doluysa nil.
    private func reserve(_ spot: Spot) -> Int? {
        release()
        for i in 0..<Self.capacity(of: spot) where Self.seatTaken["\(spot)#\(i)"] == nil {
            Self.seatTaken["\(spot)#\(i)"] = worker.id
            reservedSeat = (spot, i)
            return i
        }
        return nil
    }

    private func release() {
        if let r = reservedSeat, Self.seatTaken["\(r.spot)#\(r.index)"] == worker.id {
            Self.seatTaken["\(r.spot)#\(r.index)"] = nil
        }
        reservedSeat = nil
    }

    private var seatIndex: Int { reservedSeat?.index ?? 0 }

    var isOnToilet: Bool {
        if case .visiting(.toilet, _) = mode { return true }
        return false
    }

    var isUpright: Bool {
        if case .seated = mode { return false }
        if case .visiting(.sofa, _) = mode { return false }
        if case .visiting(.toilet, _) = mode { return false }
        if case .visiting(.lunch, _) = mode { return false }
        return true
    }
    private(set) var isGone = false

    /// Hayat olayının balonda görünen kısa açıklaması (molada, uyukluyor…).
    private(set) var note: String?

    /// Oturuyken kalça yüksekliği; Kenney sandalyesinin oturağına denk geliyor.
    private static let sitHeight: Float = 0.19
    private static let walkSpeed: Float = 0.75
    private static let rushSpeed: Float = 1.6

    init(worker: Worker, assets: Assets3D, layout: OfficeLayout3D, home: Home3D, station: Station3D?, variant: Int) {
        self.worker = worker
        self.home = home
        self.station = station
        self.layout = layout
        animations = assets.animations
        spotIndex = 0
        body = assets.character(variant) ?? Entity()
        // İlk mola zamanı herkes için farklı olsun, aynı anda kahveye koşmasınlar.
        nextBreakAt = Float(90 + variant % 150)
        #if DEBUG
        // Test: `-vardiyaFastBreaks YES` ile molalar birkaç saniye içinde başlar.
        if UserDefaults.standard.bool(forKey: "vardiyaFastBreaks") { nextBreakAt = Float(3 + variant % 8) }
        #endif

        entity.name = "agent:\(worker.id)"
        entity.addChild(body)
        // Kenney karakterleri mobilyaya göre iri; %75 ölçek masayla orantılı duruyor.
        // Alt ajanlar biraz daha küçük: bir bakışta ana ajandan ayrılsınlar.
        let scale: Float = worker.kind == .main ? 0.75 : 0.66
        body.scale = .init(repeating: scale)
        for name in ["root", "leg_left", "leg_right", "torso", "arm_left", "arm_right", "head"] {
            if let j = body.findEntity(named: name) {
                joints[name] = j
                rest[name] = j.position
            }
        }
        entity.components.set(CollisionComponent(shapes: [ShapeResource.generateBox(width: 0.5, height: 0.9, depth: 0.5).offsetBy(translation: [0, 0.45, 0])]))
        entity.components.set(InputTargetComponent())
        entity.components.set(GroundingShadowComponent(castsShadow: true))
        place(at: home.seat, seated: true)
    }

    // MARK: Dışarıdan gelenler

    func update(worker new: Worker, home newHome: Home3D, station newStation: Station3D?) {
        let wasDone = worker.activity == .done
        worker = new
        station = newStation
        if new.activity == .done, !wasDone { doneCheerUntil = now + 2.2 }
        if newHome != home {
            home = newHome
            if case .seated = mode { walk(to: home.seat, then: .seat, speed: Self.walkSpeed) }
        }
    }

    func enter(from door: SIMD3<Float>) {
        place(at: door, seated: false)
        walk(to: home.seat, then: .seat, speed: Self.walkSpeed)
    }

    func leave(to door: SIMD3<Float>) {
        isLeaving = true
        note = String(localized: "Shift over")
        walk(to: door, then: .exit, speed: Self.walkSpeed)
    }

    /// Zarf masaya ulaştı: kısa bir "aldım" hareketi.
    func receive() {
        receiveUntil = now + 0.8
    }

    var deskTop: SIMD3<Float> { home.desk + [0, Station3D.deskHeight + 0.1, 0] }

    /// Balonun bağlanacağı nokta: başın üstü.
    var headPoint: SIMD3<Float> {
        let standingHeight: Float = 0.62
        if case .seated = mode { return entity.position + [0, 0.45, 0] }
        return entity.position + [0, standingHeight, 0]
    }

    // MARK: Kare döngüsü

    func tick(dt: Float, time: Float) {
        now = time
        clipTime += dt
        decide()
        move(dt: dt)
        animate(dt: dt)
    }

    private var idleSeconds: TimeInterval {
        guard worker.activity == .idle, let last = worker.lastEventAt else { return 0 }
        return Date.now.timeIntervalSince(last)
    }

    private var isRebelling: Bool {
        worker.failureStreak >= 3 && worker.activity.isBusy
    }

    /// Gerçek duruma göre nerede olması gerektiğine karar verir.
    private func decide() {
        guard !isLeaving else { return }
        let a = worker.activity
        let mustBeAtDesk = a.isBusy || a.needsYou || a == .done || a == .thinking

        switch mode {
        case .seated:
            if isRebelling {
                walk(to: home.seat + [0.45, 0, 0.1], then: .rebel, speed: Self.walkSpeed)
                return
            }
            note = idleSeconds > 20 * 60 ? String(localized: "Dozing off") : nil
            // Uzun süre emir bekleyen ajan arada bir mola verir.
            if !mustBeAtDesk, idleSeconds > 120, now > nextBreakAt {
                let roll = Int(now * 1000 + Float(spotIndex) * 37) % 10
                var spot: Spot = roll < 4 ? .coffee : (roll < 6 ? .water : (roll < 8 ? .toilet : .sofa))
                // Öğle arası (12:00–13:30): o gün henüz yemediyse yemek masasına
                let day = Calendar.current.component(.day, from: .now)
                let hour = officeHour()
                if hour >= 12, hour < 13.5, lunchDay != day {
                    spot = .lunch
                    lunchDay = day
                }
                #if DEBUG
                // Test: `-vardiyaSpot toilet|water|sofa|coffee|lunch` ile mola yerini zorla
                switch UserDefaults.standard.string(forKey: "vardiyaSpot") {
                case "toilet": spot = .toilet
                case "water": spot = .water
                case "sofa": spot = .sofa
                case "coffee": spot = .coffee
                case "lunch": spot = .lunch
                default: break
                }
                #endif
                // Lavabo tek kişilik; seçilen yer doluysa sırayla başka bir mola yerine bakar.
                var chosen: Spot?
                for candidate in [spot, .coffee, .water, .sofa] {
                    if candidate == .toilet {
                        guard Self.toiletOccupant == nil else { continue }
                        Self.toiletOccupant = worker.id
                        chosen = .toilet
                        break
                    }
                    if reserve(candidate) != nil { chosen = candidate; break }
                }
                if let chosen {
                    walk(to: target(for: chosen), then: .spot(chosen), speed: Self.walkSpeed)
                } else {
                    // Her yer dolu: masasında biraz daha oturur.
                    nextBreakAt = now + 30
                }
            }
        case .visiting(let spot, let until):
            if mustBeAtDesk {
                walk(to: home.seat, then: .seat, speed: Self.rushSpeed)
            } else if now > until {
                // Tuvaletten sonra çıkmadan önce el yıkanır.
                if spot == .toilet {
                    walk(to: layout.sinkSpot, then: .spot(.sink), speed: Self.walkSpeed)
                } else {
                    walk(to: home.seat, then: .seat, speed: Self.walkSpeed)
                }
            }
        case .walking(_, let then, let speed):
            // İş geldiyse moladan koşarak dön.
            if mustBeAtDesk, case .spot = then {
                walk(to: home.seat, then: .seat, speed: Self.rushSpeed)
            } else if mustBeAtDesk, case .seat = then, speed < Self.rushSpeed {
                walk(to: home.seat, then: .seat, speed: Self.rushSpeed)
            }
        case .standing:
            if !isRebelling {
                note = nil
                walk(to: home.seat, then: .seat, speed: Self.walkSpeed)
            }
        }
    }

    private func target(for spot: Spot) -> SIMD3<Float> {
        switch spot {
        case .coffee:
            // Tezgâh boyunca yan yana, her biri ayrılmış yerinde.
            return [0.3 + Float(seatIndex) * 0.3, 0, layout.coffeeSpot.z]
        case .toilet:
            return layout.toiletSpot
        case .sofa:
            // Üç kişilik kanepenin minderleri, yan yana. Kanepe x=0.3'te duvara dayalı, +x'e bakıyor;
            // minderin ortası arkalığın biraz önünde.
            return [0.36, 0, layout.depth / 2 + 0.1 + (Float(seatIndex) - 1) * 0.3]
        case .water:
            // Sebilin önünde sıra
            return layout.waterSpot + [0, 0, 0.38 * Float(seatIndex)]
        case .lunch:
            return layout.diningSeats[seatIndex % 4].0
        case .sink:
            return layout.sinkSpot
        }
    }

    /// Molada hangi yöne bakar.
    private func facing(for spot: Spot) -> Float {
        switch spot {
        case .coffee, .water, .sink: .pi
        case .toilet, .sofa: .pi / 2
        case .lunch: layout.diningSeats[seatIndex % 4].1
        }
    }

    private func walk(to destination: SIMD3<Float>, then: Arrival, speed: Float) {
        if case .spot(.toilet) = then {} else if Self.toiletOccupant == worker.id { Self.toiletOccupant = nil }
        // Mola yerinden ayrılıyorsa ayırdığı koltuğu bırakır.
        if case .spot(let s) = then, let r = reservedSeat, r.spot == s {} else { release() }
        var path: [SIMD3<Float>]
        let fromBooth = inBooth(entity.position), toBooth = inBooth(destination)
        switch (fromBooth, toBooth) {
        case (true, true):
            // Kabin içinde (tuvalet → lavabo) doğrudan
            path = [destination]
        case (true, false):
            let inside: SIMD3<Float> = [OfficeLayout3D.boothWidth - 0.3, 0, layout.boothDoorZ]
            path = [inside, layout.toiletDoor] + route(from: layout.toiletDoor, to: destination)
        case (false, true):
            // Lavabo kabinine kapıdan girilir.
            let inside: SIMD3<Float> = [OfficeLayout3D.boothWidth - 0.3, 0, layout.boothDoorZ]
            path = route(from: entity.position, to: layout.toiletDoor) + [inside, destination]
        case (false, false):
            path = route(from: entity.position, to: destination)
        }
        mode = .walking(path: path, then: then, speed: speed)
        switch then {
        case .spot(.coffee): note = String(localized: "Coffee break")
        case .spot(.toilet): note = String(localized: "Restroom")
        case .spot(.sofa): note = String(localized: "Stretching")
        case .spot(.water): note = String(localized: "Getting water")
        case .spot(.lunch): note = String(localized: "At lunch")
        case .spot(.sink): note = String(localized: "Washing hands")
        case .seat: note = speed >= Self.rushSpeed ? String(localized: "Rushing back") : nil
        case .exit: note = String(localized: "Shift over")
        case .rebel: note = nil
        }
    }

    private func inBooth(_ p: SIMD3<Float>) -> Bool {
        layout.inBooth(p)
    }

    /// Masaların arasından değil, koridorlardan geçen basit bir rota:
    /// masa → orta koridor → odanın üst koridoru → ana koridor (kapı hizası) → hedef.
    private func route(from a: SIMD3<Float>, to b: SIMD3<Float>) -> [SIMD3<Float>] {
        // Kantine gidiş/dönüş sağ koridordan, geri kalan her şey sol koridordan.
        let toCanteen = a.x > layout.roomsEndX || b.x > layout.roomsEndX
        let mainX = toCanteen ? layout.rightHubX : layout.leftHubX
        func roomIndex(of p: SIMD3<Float>) -> Int? {
            for r in 0..<layout.roomCount {
                let o = layout.roomOrigin(r)
                if p.x >= o.x - 0.05, p.x <= o.x + layout.roomWidth + 0.05,
                   p.z >= o.y - 0.05, p.z <= o.y + layout.roomDepth + 0.05 { return r }
            }
            return nil
        }
        func exitPoints(_ p: SIMD3<Float>) -> [SIMD3<Float>] {
            guard let r = roomIndex(of: p) else { return [] }
            let o = layout.roomOrigin(r)
            let mid = o.x + 1.45
            let top = o.y + 0.12
            return [[mid, 0, p.z], [mid, 0, top], [mainX, 0, top]]
        }
        var points: [SIMD3<Float>] = []
        let out = exitPoints(a)
        points += out
        let inn = Array(exitPoints(b).reversed())
        let startZ = (out.last ?? a).z
        let endZ = (inn.first ?? b).z
        if out.isEmpty { points.append([mainX, 0, a.z]) }
        if abs(startZ - endZ) > 0.01 || out.isEmpty || inn.isEmpty {
            points.append([mainX, 0, startZ])
            points.append([mainX, 0, endZ])
        }
        points += inn
        if inn.isEmpty { points.append([mainX, 0, b.z]) }
        points.append(b)
        // Peş peşe aynı noktaları ayıkla
        var clean: [SIMD3<Float>] = []
        for p in points where clean.last.map({ simd_distance($0, p) > 0.02 }) ?? true { clean.append(p) }
        return clean
    }

    private func move(dt: Float) {
        switch mode {
        case .walking(var path, let then, let speed):
            guard let next = path.first else { arrive(then); return }
            var p = entity.position
            p.y = 0
            let d = next - p
            let dist = simd_length(d)
            if dist < 0.03 {
                path.removeFirst()
                mode = .walking(path: path, then: then, speed: speed)
                if path.isEmpty { arrive(then) }
                return
            }
            let step = min(dist, speed * dt)
            p += d / dist * step
            entity.position = p
            turn(toward: atan2(d.x, d.z), dt: dt, rate: 10)
        case .seated:
            entity.position = home.seat + [0, Self.sitHeight, 0]
            turn(toward: 0, dt: dt, rate: 8)
        case .visiting(let spot, _):
            // Kahve makinesine, sebile, lavaboya dön; kanepede / masada oturur.
            let face = facing(for: spot)
            if spot == .sofa || spot == .toilet || spot == .lunch {
                var p = entity.position
                p.y += (Self.sitHeight + 0.02 - p.y) * min(1, dt * 6)
                entity.position = p
            }
            turn(toward: face, dt: dt, rate: 6)
        case .standing:
            turn(toward: 0.4, dt: dt, rate: 6)
        }
    }

    private func arrive(_ then: Arrival) {
        switch then {
        case .seat:
            mode = .seated
            note = nil
            nextBreakAt = now + Float.random(in: 240...480)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "vardiyaFastBreaks") { nextBreakAt = now + Float.random(in: 4...10) }
            #endif
        case .spot(let spot):
            let stay: Float
            switch spot {
            case .sink: stay = .random(in: 3...4.5)
            case .water: stay = .random(in: 6...9)
            case .lunch: stay = .random(in: 40...70)
            case .toilet: stay = .random(in: 14...22)
            default: stay = .random(in: 12...20)
            }
            mode = .visiting(spot, until: now + stay)
        case .exit:
            isGone = true
            if Self.toiletOccupant == worker.id { Self.toiletOccupant = nil }
            release()
        case .rebel:
            mode = .standing
            note = String(localized: "On strike!")
        }
    }

    private func turn(toward target: Float, dt: Float, rate: Float) {
        var diff = target - yaw
        while diff > .pi { diff -= 2 * .pi }
        while diff < -.pi { diff += 2 * .pi }
        yaw += diff * min(1, dt * rate)
        entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
    }

    private func place(at p: SIMD3<Float>, seated: Bool) {
        entity.position = seated ? p + [0, Self.sitHeight, 0] : p
        mode = seated ? .seated : .standing
        yaw = 0
        entity.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
    }

    // MARK: Animasyon

    private typealias Pose = [String: (rotation: simd_quatf?, translation: SIMD3<Float>?)]

    private func rot(_ angle: Float, _ axis: SIMD3<Float>) -> simd_quatf {
        simd_quatf(angle: angle, axis: axis)
    }

    /// Kenney karakterlerinin kolları bağlanma pozunda yatay (T-pozu): sol kol +x, sağ kol −x.
    /// Bu yüzden kolu "şu yöne çevir" diye yönlendiriyoruz. `d` sol kol için verilir
    /// (x+ = dışa, y+ = yukarı, z+ = öne); sağ kol için x aynalanır.
    private func armPose(_ pose: inout Pose, left d: SIMD3<Float>, right r: SIMD3<Float>? = nil) {
        let rd = r ?? SIMD3(-d.x, d.y, d.z)
        pose["arm_left"] = (simd_quatf(from: [1, 0, 0], to: normalize(d)), nil)
        pose["arm_right"] = (simd_quatf(from: [-1, 0, 0], to: normalize(rd)), nil)
    }

    private func animate(dt: Float) {
        var pose: Pose
        let t = clipTime

        switch mode {
        case .walking(_, _, let speed):
            pose = animations.sample("walk", at: t * speed / Self.walkSpeed)
        case .visiting(let spot, _):
            switch spot {
            case .coffee, .water, .sink: pose = animations.sample("interact-right", at: t * (spot == .sink ? 1.4 : 0.6))
            case .lunch:
                // Yemek yiyor: sağ eli tabakla ağzı arasında gidip geliyor
                pose = animations.sample("sit", at: 0)
                let bite = (sin(t * 2.4) + 1) / 2
                armPose(&pose, left: [-0.1, -0.5, 0.9], right: [0.1 + 0.2 * bite, -0.45 + 1.0 * bite, 0.9])
                pose["head"] = (rot(0.15 - 0.1 * bite, [1, 0, 0]), nil)
            case .toilet:
                // Dirsekler dizlerde, düşünceli
                pose = animations.sample("sit", at: 0)
                pose["head"] = (rot(0.25, [1, 0, 0]), nil)
                armPose(&pose, left: [-0.15, -0.7, 0.7])
            case .sofa:
                // Kanepede yayılmış: oturma pozu, kollar yanlarda, etrafa bakınıyor
                pose = animations.sample("sit", at: 0)
                pose["torso"] = (rot(-0.15, [1, 0, 0]), nil)
                pose["head"] = (rot(0.4 * sin(t * 0.3), [0, 1, 0]), nil)
                // Kollar iki yana, kanepenin sırtına doğru
                armPose(&pose, left: [0.8, -0.35, -0.3])
            }
        case .standing:
            // İsyan: hayır jesti + iki kol havada
            pose = animations.sample("emote-no", at: t)
            let shake = sin(t * 9) * 0.3
            armPose(&pose, left: [0.2 + shake, 1, 0.1], right: [-0.2 + shake, 1, 0.1])
        case .seated:
            pose = seatedPose(t: t)
        }
        apply(pose, dt: dt)
    }

    /// Oturuyken yaptığı işe göre üst gövde: yazıyor, okuyor, izliyor, düşünüyor, el kaldırıyor…
    private func seatedPose(t: Float) -> Pose {
        var pose = animations.sample("sit", at: 0)
        let x: SIMD3<Float> = [1, 0, 0], y: SIMD3<Float> = [0, 1, 0], z: SIMD3<Float> = [0, 0, 1]
        let a = worker.activity

        /// Klavyede yazma: kollar öne, masaya; eller sırayla tuşlara iner, arada sağa sola kayar.
        /// `speed` 1 hızlı yazma, 0.5 ara ara komut girme.
        func typing(speed: Float) {
            let f = 11 * speed
            let left = max(0, sin(t * f)) * 0.22, right = max(0, sin(t * f + .pi)) * 0.22
            let slide = 0.06 * sin(t * f * 0.23)
            armPose(&pose, left: [-0.14 + slide, -0.42 + left, 1], right: [0.14 + slide, -0.42 + right, 1])
            pose["torso"] = (rot(0.1 + 0.015 * sin(t * f * 0.5), x), nil)
        }

        if now < receiveUntil {
            // Zarfı aldı: iki eliyle öne uzanır.
            armPose(&pose, left: [-0.05, 0.05, 1])
            pose["head"] = (rot(0.2, x), nil)
            return pose
        }
        if now < doneCheerUntil {
            let cheer = animations.sample("emote-yes", at: t)
            for j in ["torso", "head", "arm_left", "arm_right"] { if let v = cheer[j] { pose[j] = v } }
            return pose
        }

        switch a {
        case .writing, .tool, .browsing:
            typing(speed: 1)
            pose["head"] = (rot(0.06 + 0.03 * sin(t * 2), x), nil)
        case .reading, .searching:
            // Elleri masada, ekrana eğilmiş okuyor
            armPose(&pose, left: [-0.08, -0.75, 0.7])
            pose["torso"] = (rot(0.08, x), nil)
            pose["head"] = (rot(0.22, x) * rot(0.12 * sin(t * 0.9), y), nil)
        case .running:
            // Komut çalışırken ara ara yazıp çıktıyı izler: daha yavaş tuşlama, ekrana bakış.
            typing(speed: 0.55)
            pose["head"] = (rot(-0.02, x) * rot(0.1 * sin(t * 0.8), y), nil)
        case .thinking:
            // Eli çenesinde
            armPose(&pose, left: [-0.1, -0.55, 0.85], right: [0.35, 0.75, 0.6])
            pose["head"] = (rot(0.1, x) * rot(0.15, z) * rot(0.2 * sin(t * 0.7), y), nil)
        case .delegating:
            let talk = animations.sample("interact-left", at: t * 0.8)
            for j in ["torso", "head", "arm_left", "arm_right"] { if let v = talk[j] { pose[j] = v } }
        case .asking, .awaitingApproval:
            // El kaldırıp sizi çağırır
            armPose(&pose, left: [-0.1, -0.55, 0.85], right: [-0.2 + 0.35 * sin(t * 7), 1, 0.15])
            pose["head"] = (rot(-0.15, x) * rot(0.35, y), nil)
        case .done:
            armPose(&pose, left: [-0.1, -0.6, 0.8])
            pose["torso"] = (rot(-0.08, x), nil)
        case .idle:
            if idleSeconds > 20 * 60 {
                // Uyukluyor: kafa öne düşmüş, hafif nefes alıp veriyor
                armPose(&pose, left: [-0.15, -0.3, 1])
                pose["torso"] = (rot(0.32 + 0.02 * sin(t * 1.2), x), nil)
                pose["head"] = (rot(0.55, x), nil)
            } else {
                // Emir bekliyor: elleri masada, etrafa bakınıyor
                armPose(&pose, left: [-0.1, -0.55, 0.85])
                pose["torso"] = (rot(-0.04, x), nil)
                pose["head"] = (rot(0.35 * sin(t * 0.35), y) * rot(-0.05, x), nil)
            }
        }
        return pose
    }

    /// Hedef poza yumuşak geçiş; klipler arası sert sıçrama olmasın.
    private func apply(_ pose: Pose, dt: Float) {
        let k = 1 - exp(-dt * 14)
        for (name, joint) in joints {
            let targetRot = pose[name]?.rotation ?? simd_quatf(angle: 0, axis: [0, 1, 0])
            let targetPos = pose[name]?.translation ?? rest[name] ?? joint.position
            joint.orientation = simd_slerp(joint.orientation, targetRot, k)
            joint.position += (targetPos - joint.position) * k
        }
    }
}
