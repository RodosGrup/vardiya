import AppKit
import Observation
import RealityKit
import SwiftUI

/// Balon ve rozetlerin ekrandaki yeri; sahne her karede günceller, SwiftUI üstüne çizer.
struct OverlayAnchor: Equatable {
    var head: CGPoint
    var desk: CGPoint
    var depth: Float
    var note: String?
    /// Lavaboda: üstten görünmesin diye karakterin üstüne sansür kutusu.
    var censor: CGPoint?
}

/// 3D ofis: sahne kurulumu, ışıklar, kamera, ajanların senkronu ve kare döngüsü.
@MainActor
@Observable
final class OfficeWorld {
    // SwiftUI katmanının okuduğu durum
    private(set) var anchors: [String: OverlayAnchor] = [:]
    private(set) var speech: [String: SpeechBubble] = [:]
    private(set) var isReady = false

    @ObservationIgnored let root = Entity()
    @ObservationIgnored private var assets: Assets3D?
    @ObservationIgnored private var layout = OfficeLayout3D(roomCount: 1)
    @ObservationIgnored private var builtRooms: [String] = []
    @ObservationIgnored private let furniture = Entity()
    @ObservationIgnored private let people = Entity()
    @ObservationIgnored private let effects = Entity()
    @ObservationIgnored private var agents: [String: Agent3D] = [:]
    @ObservationIgnored private var stations: [String: Station3D] = [:]
    @ObservationIgnored private var envelopes: [Envelope3D] = []
    @ObservationIgnored private var lastShifts: [Shift] = []
    @ObservationIgnored private var hasSynced = false

    // Işık
    @ObservationIgnored private let sun = DirectionalLight()
    @ObservationIgnored private let fill = DirectionalLight()
    @ObservationIgnored private let ibl = Entity()
    @ObservationIgnored private var skyBack = ModelEntity()
    @ObservationIgnored private var skyLeft = ModelEntity()
    @ObservationIgnored private var lastLightingUpdate: Date = .distantPast
    @ObservationIgnored private var ceilingLamps: [CeilingLamp] = []
    @ObservationIgnored private var boothDoor: Entity?
    @ObservationIgnored private var boothSign: ModelEntity?
    @ObservationIgnored private var doorAngle: Float = 0
    @ObservationIgnored private var signOccupied: Bool?
    /// Oda başına doluluk: 1 = biri çalışıyor, 0.55 = dolu ama boşta, 0 = kimse yok.
    @ObservationIgnored private var roomLoad: [Int: Float] = [:]
    @ObservationIgnored private(set) var daylight: Float = 1

    // Kamera
    @ObservationIgnored let camera = PerspectiveCamera()
    @ObservationIgnored var viewport: CGSize = .init(width: 1000, height: 700)
    @ObservationIgnored private var yaw: Float = .pi / 4
    @ObservationIgnored private var pitch: Float = 0.62
    @ObservationIgnored private var distance: Float = 12
    @ObservationIgnored private var target: SIMD3<Float> = .zero
    @ObservationIgnored private var goal: (target: SIMD3<Float>, distance: Float)?
    @ObservationIgnored private var dragStart: (yaw: Float, pitch: Float)?
    @ObservationIgnored private let fov: Float = 38

    @ObservationIgnored private var selectionRing = ModelEntity()
    @ObservationIgnored var selectedID: String?
    @ObservationIgnored var onSelect: ((String) -> Void)?

    /// Son karenin zamanı; sahne çizilmiyorsa görünüm kendini yeniden kurar.
    @ObservationIgnored private(set) var lastTickAt: Date = .distantPast
    @ObservationIgnored private var overlayClock: Float = 0
    @ObservationIgnored private var time: Float = 0

    // MARK: - Kurulum

    func setup() async {
        guard assets == nil else { return }
        let assets = await Assets3D.load()
        self.assets = assets

        root.addChild(furniture)
        root.addChild(people)
        root.addChild(effects)

        camera.camera.fieldOfViewInDegrees = fov
        root.addChild(camera)

        sun.light.intensity = 3200
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 30, depthBias: 3)
        root.addChild(sun)
        fill.light.intensity = 500
        root.addChild(fill)

        ibl.components.set(ImageBasedLightComponent(source: .single(Self.makeEnvironment()), intensityExponent: 0.6))
        root.addChild(ibl)

        let ring = MeshResource.generateCylinder(height: 0.006, radius: 0.42)
        var ringMat = PhysicallyBasedMaterial()
        ringMat.baseColor = .init(tint: NSColor(Theme.accent).withAlphaComponent(0.55))
        ringMat.emissiveColor = .init(color: NSColor(Theme.accent))
        ringMat.emissiveIntensity = 0.8
        ringMat.blending = .transparent(opacity: 0.55)
        selectionRing = ModelEntity(mesh: ring, materials: [ringMat])
        selectionRing.isEnabled = false
        root.addChild(selectionRing)

        isReady = true
        if !lastShifts.isEmpty { sync(lastShifts) }
        #if DEBUG
        // Test kolaylığı: `-vardiyaFocus N` ile N'inci ajana, `-vardiyaHour H` ile günün saatine atla.
        let focusIndex = UserDefaults.standard.integer(forKey: "vardiyaFocus")
        if focusIndex > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                let ids = lastShifts.flatMap(\.workers).map(\.id)
                if focusIndex <= ids.count { onSelect?(ids[focusIndex - 1]); focus(on: ids[focusIndex - 1]); distance = 2.6; goal?.distance = 2.6 }
            }
        }
        #endif
    }

    // MARK: - Ofis inşası

    /// Oda sayısı değişince mobilyaları baştan dizeriz; ajanlar yerinde kalır, yeni masalarına yürür.
    private func rebuild(rooms: [Room]) {
        guard let assets else { return }
        let capacity = rooms.map { min(OfficeLayout3D.maxPerRoom, $0.shifts.reduce(0) { $0 + 1 + $1.subagents.count }) }.max() ?? 1
        let ids = rooms.map { "\($0.id):\($0.shifts.reduce(0) { $0 + 1 + $1.subagents.count })" } + ["cap\(capacity)"]
        guard ids != builtRooms else { return }
        builtRooms = ids
        layout = OfficeLayout3D(roomCount: rooms.count, capacity: capacity)

        furniture.children.removeAll()
        stations.removeAll()
        ceilingLamps.removeAll()

        buildShell(assets)
        buildAmenities(assets)
        for (r, room) in rooms.enumerated() {
            let occupants = min(OfficeLayout3D.maxPerRoom, room.shifts.reduce(0) { $0 + 1 + $1.subagents.count })
            for slot in 0..<occupants {
                let station = Station3D(assets: assets, at: layout.desk(room: r, slot: slot))
                furniture.addChild(station.entity)
                stations["\(room.id)#\(slot)"] = station
            }
            let o = layout.roomOrigin(r)
            // Odayı zeminde hafif bir halıyla belirginleştir.
            let rug = ModelEntity(mesh: .generatePlane(width: layout.roomWidth - 0.1, depth: layout.roomDepth - 0.1, cornerRadius: 0.12),
                                  materials: [SimpleMaterial(color: NSColor(srgbRed: 0.8, green: 0.85, blue: 0.92, alpha: 1), roughness: 0.95, isMetallic: false)])
            rug.position = [o.x + layout.roomWidth / 2, 0.052, o.y + layout.roomDepth / 2]
            furniture.addChild(rug)
        }
        buildCeilingLamps(assets, rooms: rooms.count)
        applyLightReceivers(furniture)
        frameAll(animated: hasSynced)
    }

    private func buildShell(_ assets: Assets3D) {
        let w = Int(ceil(layout.width)), d = Int(ceil(layout.depth))
        // Ahşap zemin döşemeleri (1×1 m)
        for x in 0..<w {
            for z in 0..<d {
                let tile = assets.prop("floorFull")
                tile.position = [Float(x) + 0.5, 0, Float(z) + 0.5]
                furniture.addChild(tile)
            }
        }
        // Arka duvar: pencereler ve kapı. Kapının yeri layout.door.
        let doorIndex = Int(layout.door.x)
        for x in 0..<w {
            let kind = x == doorIndex ? "wallDoorway" : (x % 2 == 1 ? "wallWindow" : "wall")
            let piece = assets.prop(kind)
            piece.position = [Float(x) + 0.5, 0, 0]
            furniture.addChild(piece)
        }
        // Sol duvar
        for z in 0..<d {
            let piece = assets.prop(z % 2 == 1 ? "wallWindow" : "wall")
            piece.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
            piece.position = [0, 0, Float(z) + 0.5]
            furniture.addChild(piece)
        }
        // Pencerelerden görünen gökyüzü: duvarların hemen arkasında aydınlatmasız düzlemler.
        // Duvar yüksekliğinde ve hemen arkasında: yukarıdan bakınca duvarın ardında kalır, yalnızca pencerelerden görünür.
        skyBack = ModelEntity(mesh: .generatePlane(width: Float(w), height: 1.25), materials: [UnlitMaterial(color: .white)])
        skyBack.position = [Float(w) / 2, 0.62, -0.07]
        furniture.addChild(skyBack)
        skyLeft = ModelEntity(mesh: .generatePlane(width: Float(d), height: 1.25), materials: [UnlitMaterial(color: .white)])
        skyLeft.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        skyLeft.position = [-0.07, 0.62, Float(d) / 2]
        furniture.addChild(skyLeft)
        updateLighting(force: true)
    }

    private func buildAmenities(_ assets: Assets3D) {
        func place(_ name: String, _ p: SIMD3<Float>, yaw: Float = 0, scale: Float = 1) {
            let e = assets.prop(name, scale: scale)
            e.position = p
            e.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            furniture.addChild(e)
        }
        // Kahve köşesi
        place("kitchenBar", [0.55, 0, 0.3])
        place("kitchenBar", [0.98, 0, 0.3])
        place("kitchenCoffeeMachine", [layout.coffeeMachine.x, 0.42, 0.28])
        place("kitchenFridgeSmall", [1.45, 0, 0.3])
        place("plantSmall1", [0.3, 0.42, 0.28])
        place("trashcan", [0.25, 0, 1.0], scale: 0.6)
        // Dinlenme alanı
        place("loungeSofa", [0.3, 0, layout.depth / 2 + 0.1], yaw: .pi / 2)
        place("pottedPlant", [0.3, 0, layout.depth / 2 - 0.7])
        place("lampRoundFloor", [0.3, 0, layout.depth / 2 + 0.75])
        // Lavabo: bölmeli köşe
        // Lavabo: üstü açık, dört duvarlı kabin. Sağ duvarda kapı; el yıkama lavabosu içeride.
        let d = layout.depth
        let bw = OfficeLayout3D.boothWidth, bd = OfficeLayout3D.boothDepth
        place("toilet", [0.28, 0, d - 0.55], yaw: .pi / 2, scale: 0.7)
        place("bathroomSink", [layout.sinkSpot.x, 0, d - bd + 0.12], scale: 0.7)
        var tile = PhysicallyBasedMaterial()
        tile.baseColor = .init(tint: NSColor(srgbRed: 0.86, green: 0.92, blue: 0.95, alpha: 1))
        tile.roughness = 0.6
        func partition(from a: SIMD2<Float>, to b: SIMD2<Float>) {
            let len = simd_distance(a, b)
            let wall = ModelEntity(mesh: .generateBox(width: len, height: 0.85, depth: 0.05, cornerRadius: 0.01), materials: [tile])
            let mid = (a + b) / 2
            wall.position = [mid.x, 0.425, mid.y]
            wall.orientation = simd_quatf(angle: -atan2(b.y - a.y, b.x - a.x), axis: [0, 1, 0])
            furniture.addChild(wall)
        }
        let doorHalf: Float = 0.3
        partition(from: [0, d - bd], to: [bw, d - bd])                         // arka
        partition(from: [0, d - 0.02], to: [bw, d - 0.02])                     // ön
        partition(from: [bw, d - bd], to: [bw, layout.boothDoorZ - doorHalf])  // sağ, kapının üstü
        partition(from: [bw, layout.boothDoorZ + doorHalf], to: [bw, d])       // sağ, kapının altı
        // Kapı: menteşesi kapı boşluğunun üst ucunda; biri yaklaşınca açılır.
        let hinge = Entity()
        hinge.position = [bw, 0, layout.boothDoorZ - doorHalf]
        var doorMat = PhysicallyBasedMaterial()
        doorMat.baseColor = .init(tint: NSColor(srgbRed: 0.62, green: 0.75, blue: 0.85, alpha: 1))
        doorMat.roughness = 0.5
        let door = ModelEntity(mesh: .generateBox(width: 0.04, height: 0.8, depth: doorHalf * 2 - 0.02, cornerRadius: 0.01), materials: [doorMat])
        door.position = [0, 0.4, doorHalf]
        let knob = ModelEntity(mesh: .generateSphere(radius: 0.018), materials: [SimpleMaterial(color: .darkGray, isMetallic: true)])
        knob.position = [0.035, 0, doorHalf - 0.08]
        door.addChild(knob)
        hinge.addChild(door)
        furniture.addChild(hinge)
        boothDoor = hinge
        // Kapı tabelası
        let sign = ModelEntity(mesh: .generateBox(width: 0.01, height: 0.09, depth: 0.14, cornerRadius: 0.01), materials: [UnlitMaterial(color: NSColor(Theme.success))])
        sign.position = [bw + 0.03, 0.75, layout.boothDoorZ - doorHalf - 0.12]
        furniture.addChild(sign)
        boothSign = sign

        // Kantin: yemek masası, dört sandalye, tabaklar ve sebil
        place("tableRound", layout.diningTable)
        for (p, face) in layout.diningSeats {
            place("chair", p, yaw: face)
        }
        var plateMat = PhysicallyBasedMaterial()
        plateMat.baseColor = .init(tint: .white)
        plateMat.roughness = 0.3
        for (p, _) in layout.diningSeats {
            let plate = ModelEntity(mesh: .generateCylinder(height: 0.012, radius: 0.07), materials: [plateMat])
            let towardTable = (layout.diningTable - p) * 0.62
            plate.position = p + towardTable + [0, 0.38, 0]
            furniture.addChild(plate)
        }
        place("kitchenCabinet", [layout.canteenX + 0.35, 0, 0.3])
        furniture.addChild(Self.makeWaterCooler(at: layout.waterCooler))
        place("plantSmall2", [layout.canteenX + 0.9, 0.0, 0.3])

        // Kapı yanı
        place("coatRackStanding", [layout.door.x + 0.6, 0, 0.3])
        place("pottedPlant", [layout.width - 0.4, 0, 0.35])
        place("bookcaseOpen", [layout.width - 1.1, 0, 0.2])
    }

    /// Tavandan sarkan avizeler: her masa sırasının ve ortak alanların üstünde.
    /// Hava kararınca yanarlar; içinde çalışan olan odalar tam, boş kalanlar loş.
    private func buildCeilingLamps(_ assets: Assets3D, rooms: Int) {
        func hang(_ p: SIMD3<Float>, room: Int?) {
            let lamp = CeilingLamp(assets: assets, at: p, room: room)
            furniture.addChild(lamp.entity)
            ceilingLamps.append(lamp)
        }
        for r in 0..<rooms {
            let o = layout.roomOrigin(r)
            for row in 0..<layout.deskRows {
                let z = o.y + layout.station(row * layout.deskCols).y - 0.15
                hang([o.x + layout.roomWidth / 2, 0, z], room: r)
            }
        }
        hang([0.85, 0, 0.9], room: nil)
        hang([0.95, 0, layout.depth / 2 + 0.1], room: nil)
        hang([0.95, 0, layout.depth - 0.55], room: nil)
        hang(layout.diningTable, room: nil)
    }

    /// Sebil: beyaz gövde, üstünde mavi damacana, önünde iki musluk. Pakette olmadığı için elle kuruyoruz.
    private static func makeWaterCooler(at p: SIMD3<Float>) -> Entity {
        let root = Entity()
        root.position = p
        var body = PhysicallyBasedMaterial()
        body.baseColor = .init(tint: NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1))
        body.roughness = 0.4
        let base = ModelEntity(mesh: .generateBox(width: 0.24, height: 0.5, depth: 0.24, cornerRadius: 0.03), materials: [body])
        base.position = [0, 0.25, 0]
        root.addChild(base)

        var water = PhysicallyBasedMaterial()
        water.baseColor = .init(tint: NSColor(srgbRed: 0.35, green: 0.65, blue: 0.95, alpha: 1))
        water.roughness = 0.1
        water.blending = .transparent(opacity: 0.7)
        let bottle = ModelEntity(mesh: .generateCylinder(height: 0.26, radius: 0.1), materials: [water])
        bottle.position = [0, 0.63, 0]
        root.addChild(bottle)
        let cap = ModelEntity(mesh: .generateCylinder(height: 0.03, radius: 0.04), materials: [water])
        cap.position = [0, 0.78, 0]
        root.addChild(cap)

        for (x, color) in [(-0.05, NSColor(srgbRed: 0.2, green: 0.45, blue: 0.95, alpha: 1)), (0.05, NSColor(srgbRed: 0.9, green: 0.25, blue: 0.2, alpha: 1))] {
            let tap = ModelEntity(mesh: .generateBox(width: 0.03, height: 0.03, depth: 0.04, cornerRadius: 0.005), materials: [SimpleMaterial(color: color, isMetallic: false)])
            tap.position = [Float(x), 0.38, 0.13]
            root.addChild(tap)
        }
        root.components.set(GroundingShadowComponent(castsShadow: true))
        return root
    }

    /// Ortam ışığı (IBL) her modele ayrıca bağlanmalı.
    private func applyLightReceivers(_ entity: Entity) {
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl))
        for child in entity.children { applyLightReceivers(child) }
    }

    // MARK: - Senkron

    func sync(_ shifts: [Shift]) {
        lastShifts = shifts
        guard let assets, isReady else { return }
        let rooms = Room.group(shifts)
        rebuild(rooms: rooms)

        var seen = Set<String>()
        roomLoad = [:]
        for (r, room) in rooms.enumerated() {
            let workers = room.shifts.flatMap(\.workers)
            roomLoad[r] = workers.contains { $0.activity.isBusy || $0.activity.needsYou } ? 1 : 0.55
            let mains = room.shifts.map { ($0.main, Optional<String>.none) }
            let subs = room.shifts.flatMap { s in s.subagents.map { ($0, Optional(s.main.id)) } }
            let people = (mains + subs.suffix(max(0, OfficeLayout3D.maxPerRoom - mains.count))).prefix(OfficeLayout3D.maxPerRoom)
            for (slot, entry) in people.enumerated() {
                let (worker, parent) = entry
                seen.insert(worker.id)
                let home = Home3D(room: r, slot: slot, seat: layout.seat(room: r, slot: slot), desk: layout.desk(room: r, slot: slot))
                let station = stations["\(room.id)#\(slot)"]
                if let agent = agents[worker.id] {
                    let before = agent.worker
                    agent.update(worker: worker, home: home, station: station)
                    detectEvents(agent: agent, before: before, parent: parent)
                } else {
                    let agent = Agent3D(worker: worker, assets: assets, layout: layout, home: home,
                                        station: station, variant: abs(worker.id.hashValue))
                    agent.layout = layout
                    applyLightReceivers(agent.entity)
                    self.people.addChild(agent.entity)
                    agents[worker.id] = agent
                    // İlk açılışta herkes masasında başlar; sonradan gelen alt ajanlar kapıdan girer.
                    if hasSynced {
                        agent.enter(from: layout.door)
                        if let parent, let from = agents[parent] {
                            launchEnvelope(from: from.deskTop, to: agent.home.desk + [0, 0.5, 0], kind: .delegate, to: agent)
                        }
                    }
                }
                agents[worker.id]?.layout = layout
            }
        }
        // Mola yerleri için benzersiz sıra: aynı tezgâh noktasına iki kişi gitmesin.
        for (i, agent) in agents.values.sorted(by: { $0.worker.id < $1.worker.id }).enumerated() {
            agent.spotIndex = i
        }
        // Gidenler kapıdan çıkar.
        for (id, agent) in agents where !seen.contains(id) && !agent.isLeaving {
            agent.leave(to: layout.door)
        }
        stations.values.forEach { $0.setOccupant(nil) }
        for agent in agents.values where !agent.isLeaving {
            agent.station?.setOccupant(agent.worker.activity)
        }
        hasSynced = true
    }

    /// Yeni istek ve yanıtları yakalayıp zarf/konuşma balonu üretir.
    private func detectEvents(agent: Agent3D, before: Worker, parent: String?) {
        let w = agent.worker
        let fresh: (Date?) -> Bool = { d in d.map { Date.now.timeIntervalSince($0) < 15 } ?? false }

        if let at = w.lastUserAt, at != before.lastUserAt, fresh(at) {
            launchEnvelope(from: layout.door + [0, 1.0, 0], to: agent.deskTop, kind: .prompt, to: agent)
            if let text = w.lastUserText {
                speech[w.id] = SpeechBubble(text: text, kind: .prompt, until: .now + 6)
            }
        }
        if let at = w.lastReplyAt, at != before.lastReplyAt, fresh(at), let text = w.lastReplyText {
            speech[w.id] = SpeechBubble(text: text, kind: .reply, until: .now + 8)
            if !w.activity.isBusy, w.kind == .main {
                launchEnvelope(from: agent.deskTop, to: layout.door + [0, 1.0, 0], kind: .reply, to: nil)
            }
        }
        if case .subagent = w.kind, w.activity == .done, before.activity != .done,
           let parent, let main = agents[parent] {
            launchEnvelope(from: agent.deskTop, to: main.deskTop, kind: .reply, to: main)
        }
    }

    private func launchEnvelope(from: SIMD3<Float>, to: SIMD3<Float>, kind: Envelope3D.Kind, to receiver: Agent3D?) {
        let env = Envelope3D(from: from, to: to, kind: kind) { [weak receiver] in receiver?.receive() }
        effects.addChild(env.entity)
        envelopes.append(env)
    }

    // MARK: - Kare döngüsü

    func tick(_ dt: Float) {
        guard isReady else { return }
        lastTickAt = .now
        let dt = min(dt, 0.1)
        time += dt
        for agent in agents.values { agent.tick(dt: dt, time: time) }
        separate(dt: dt)
        for (id, agent) in agents where agent.isGone {
            agent.entity.removeFromParent()
            agents[id] = nil
        }
        envelopes.removeAll { env in
            env.tick(dt: dt, parent: effects)
            if env.isFinished { env.entity.removeFromParent() }
            return env.isFinished
        }
        for station in stations.values { station.tick(time: time, daylight: daylight) }
        let night = 1 - daylight
        for lamp in ceilingLamps {
            let load = lamp.room.map { roomLoad[$0] ?? 0.3 } ?? 0.45
            lamp.tick(level: night * load, dt: dt)
        }

        updateBoothDoor(dt: dt)
        updateSelectionRing()
        updateCamera(dt: dt)
        updateLighting(force: false)

        overlayClock += dt
        if overlayClock > 1.0 / 30 {
            overlayClock = 0
            refreshOverlay()
        }
    }

    /// Ayaktaki ajanlar birbirine fazla yaklaşırsa yavaşça kenara çekilir; iç içe geçmesinler.
    /// Oturanlar sabit engel sayılır, yürüyen onların etrafından dolanır.
    private func separate(dt: Float) {
        let minDist: Float = 0.36
        let all = Array(agents.values.filter { !$0.isGone })
        for i in all.indices {
            for j in all.indices where j > i {
                let a = all[i], b = all[j]
                guard a.isUpright || b.isUpright else { continue }
                var d = a.entity.position - b.entity.position
                d.y = 0
                let dist = simd_length(d)
                guard dist < minDist else { continue }
                // Tam üst üsteyse rastgele değil, kimliğe göre sabit bir yöne ayır.
                let dir = dist > 0.001 ? d / dist : (a.worker.id < b.worker.id ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(-1, 0, 0))
                let push = (minDist - dist) * min(1, dt * 8)
                switch (a.isUpright, b.isUpright) {
                case (true, true):
                    a.entity.position += dir * push / 2
                    b.entity.position -= dir * push / 2
                case (true, false):
                    a.entity.position += dir * push
                case (false, true):
                    b.entity.position -= dir * push
                default: break
                }
            }
        }
    }

    /// Lavabo kapısı: kapıya 0,7 m'den yakın biri varsa açılır; tabela doluyken kırmızı.
    private func updateBoothDoor(dt: Float) {
        guard let boothDoor else { return }
        let doorPoint: SIMD3<Float> = [OfficeLayout3D.boothWidth, 0, layout.boothDoorZ]
        let someoneNear = agents.values.contains { a in
            var p = a.entity.position; p.y = 0
            return a.isUpright && simd_distance(p, doorPoint) < 0.7
        }
        let target: Float = someoneNear ? -1.6 : 0
        doorAngle += (target - doorAngle) * min(1, dt * 6)
        boothDoor.orientation = simd_quatf(angle: doorAngle, axis: [0, 1, 0])
        let occupied = Agent3D.toiletOccupant != nil
        if occupied != signOccupied {
            signOccupied = occupied
            boothSign?.model?.materials = [UnlitMaterial(color: NSColor(occupied ? Theme.warning : Theme.success))]
        }
    }

    private func updateSelectionRing() {
        guard let id = selectedID, let agent = agents[id] else {
            selectionRing.isEnabled = false
            return
        }
        selectionRing.isEnabled = true
        let p = agent.entity.position
        selectionRing.position = [p.x, 0.055, p.z]
        let pulse = 1 + 0.06 * sin(time * 3)
        selectionRing.scale = [pulse, 1, pulse]
    }

    private func refreshOverlay() {
        var next: [String: OverlayAnchor] = [:]
        var placed: [CGRect] = []
        // Yakındakiler önce yerleşir; çakışan balonlar yukarı doğru sıralanır.
        let ordered = agents.filter { !$0.value.isGone }.sorted {
            simd_distance($0.value.entity.position, camera.position) < simd_distance($1.value.entity.position, camera.position)
        }
        for (id, agent) in ordered {
            guard let head = project(agent.headPoint), let desk = project(agent.home.desk + [0, 0, 0.42]) else { continue }
            // Görüş alanının dışına düşen balonları gösterme; kenarda yarım kalmasınlar.
            let bounds = CGRect(origin: .zero, size: viewport).insetBy(dx: 40, dy: 30)
            guard bounds.contains(head.point) else { continue }
            var point = head.point
            var rect = CGRect(x: point.x - 95, y: point.y - 22, width: 190, height: 20)
            var tries = 0
            while placed.contains(where: { $0.intersects(rect) }), tries < 6 {
                point.y -= 22
                rect.origin.y -= 22
                tries += 1
            }
            placed.append(rect)
            let censor = agent.isOnToilet ? project(agent.entity.position + [0, 0.3, 0])?.point : nil
            next[id] = OverlayAnchor(head: point, desk: desk.point, depth: head.depth, note: agent.note, censor: censor)
        }
        if next != anchors { anchors = next }
        let now = Date.now
        if speech.values.contains(where: { $0.until < now }) {
            speech = speech.filter { $0.value.until >= now }
        }
    }

    // MARK: - Kamera

    func frameAll(animated: Bool = true) {
        let size = max(layout.width, layout.depth)
        let d = size * 1.05 / tan(fov * .pi / 360) * 0.52
        goal = (layout.center + [0, 0, 0.2], d)
        if !animated, let goal {
            target = goal.target
            distance = goal.distance
        }
    }

    func focus(on id: String) {
        guard let agent = agents[id] else { return }
        goal = (agent.entity.position + [0, 0.4, 0], 4.2)
    }

    func orbit(translation: CGSize, began: Bool) {
        if began || dragStart == nil { dragStart = (yaw, pitch) }
        guard let start = dragStart else { return }
        yaw = start.yaw - Float(translation.width) * 0.006
        pitch = min(1.35, max(0.18, start.pitch + Float(translation.height) * 0.004))
    }

    func endOrbit() { dragStart = nil }

    func zoom(by factor: Float) {
        goal = nil
        distance = min(30, max(2.2, distance * factor))
    }

    private func updateCamera(dt: Float) {
        if let goal {
            let k = 1 - exp(-dt * 4)
            target += (goal.target - target) * k
            distance += (goal.distance - distance) * k
            if simd_distance(target, goal.target) < 0.01, abs(distance - goal.distance) < 0.01 { self.goal = nil }
        }
        let offset = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * distance
        camera.position = target + offset
        camera.look(at: target, from: camera.position, relativeTo: nil)
    }

    /// Dünya noktasını görünüm koordinatına çevirir (SwiftUI balonları için).
    private func project(_ p: SIMD3<Float>) -> (point: CGPoint, depth: Float)? {
        let view = camera.transformMatrix(relativeTo: nil).inverse
        let c = view * SIMD4<Float>(p, 1)
        guard c.z < -0.05 else { return nil }
        let f = 1 / tan(fov * .pi / 360)
        let aspect = Float(viewport.width / max(1, viewport.height))
        let ndcX = (c.x / -c.z) * f / aspect
        let ndcY = (c.y / -c.z) * f
        let x = CGFloat((ndcX + 1) / 2) * viewport.width
        let y = CGFloat((1 - ndcY) / 2) * viewport.height
        return (CGPoint(x: x, y: y), -c.z)
    }

    // MARK: - Seçim

    func tapped(_ entity: Entity) {
        var e: Entity? = entity
        while let current = e {
            if current.name.hasPrefix("agent:") {
                let id = String(current.name.dropFirst(6))
                onSelect?(id)
                focus(on: id)
                return
            }
            e = current.parent
        }
    }

    // MARK: - Gün / gece

    /// Gerçek saate göre güneş, gökyüzü ve ortam ışığı. Dakikada bir yeterli; geçişler yavaş.
    private func updateLighting(force: Bool) {
        let now = Date.now
        guard force || now.timeIntervalSince(lastLightingUpdate) > 30 else { return }
        lastLightingUpdate = now
        apply(hour: officeHour(now))
    }

    func apply(hour: Float) {
        // 6–8 arası şafak, 18–20 arası gün batımı
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - a) / (b - a)))
            return t * t * (3 - 2 * t)
        }
        let day = smooth(6, 8, hour) * (1 - smooth(18, 20, hour))
        daylight = day
        let golden = max(0, 1 - abs(hour - 7) / 1.5) + max(0, 1 - abs(hour - 19) / 1.5)

        // Güneş gün boyu doğudan batıya, arka pencerelerin üstünden içeri vuruyor.
        let progress = min(1, max(0, (hour - 6) / 14))
        let azimuth = Float.pi * (0.15 + 0.7 * progress)
        let elevation = 0.35 + 0.55 * sin(Float.pi * progress)
        let dir = SIMD3<Float>(cos(azimuth) * cos(elevation), sin(elevation), -sin(azimuth) * cos(elevation) - 0.6)
        sun.look(at: layout.center, from: layout.center + normalize(dir) * 20, relativeTo: nil)
        let warm = NSColor(srgbRed: 1, green: 0.78, blue: 0.55, alpha: 1)
        let noon = NSColor(srgbRed: 1, green: 0.97, blue: 0.92, alpha: 1)
        sun.light.color = noon.blended(withFraction: CGFloat(min(1, golden)), of: warm) ?? noon
        sun.light.intensity = 150 + 2300 * day
        fill.look(at: layout.center, from: layout.center + [8, 6, 10], relativeTo: nil)
        fill.light.intensity = 60 + 260 * day
        fill.light.color = day > 0.5 ? .white : NSColor(srgbRed: 0.55, green: 0.62, blue: 0.95, alpha: 1)

        if var comp = ibl.components[ImageBasedLightComponent.self] {
            comp.intensityExponent = -2.2 + 1.9 * day
            ibl.components.set(comp)
        }

        let skyDay = NSColor(srgbRed: 0.62, green: 0.82, blue: 1, alpha: 1)
        let skyDusk = NSColor(srgbRed: 1, green: 0.66, blue: 0.45, alpha: 1)
        let skyNight = NSColor(srgbRed: 0.05, green: 0.08, blue: 0.2, alpha: 1)
        var sky = skyNight.blended(withFraction: CGFloat(day), of: skyDay) ?? skyDay
        sky = sky.blended(withFraction: CGFloat(min(0.7, golden * 0.6)), of: skyDusk) ?? sky
        skyBack.model?.materials = [UnlitMaterial(color: sky)]
        skyLeft.model?.materials = [UnlitMaterial(color: sky)]
    }

    /// Yumuşak, gökyüzünden zemine geçen basit bir ortam haritası (equirectangular).
    private static func makeEnvironment() -> EnvironmentResource {
        let w = 256, h = 128
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(srgbRed: 0.85, green: 0.92, blue: 1, alpha: 1),
                      CGColor(srgbRed: 1, green: 0.98, blue: 0.95, alpha: 1),
                      CGColor(srgbRed: 0.55, green: 0.5, blue: 0.45, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        let image = ctx.makeImage()!
        return try! EnvironmentResource(equirectangular: image, withName: "vardiya-sky")
    }
}

/// Tavandan sarkan avize: aşağı bakan spot ışık ve parlayan ampul.
@MainActor
final class CeilingLamp {
    static let hangHeight: Float = 1.5

    let entity = Entity()
    let room: Int?
    private let light = SpotLight()
    private let bulb: ModelEntity
    private var level: Float = 0
    private var shownLevel: Float = -1

    init(assets: Assets3D, at p: SIMD3<Float>, room: Int?) {
        self.room = room
        entity.position = [p.x, 0, p.z]
        // Kenney lambası küçük (12×23 cm); 1,4 kat büyütüp tavandan sarkıtıyoruz, kuş bakışını kapatmasın.
        let model = assets.prop("lampSquareCeiling", scale: 1.4)
        model.position = [0, Self.hangHeight - 0.32, 0]
        entity.addChild(model)

        var cord = UnlitMaterial(color: NSColor(srgbRed: 0.25, green: 0.25, blue: 0.28, alpha: 1))
        cord.blending = .opaque
        let wire = ModelEntity(mesh: .generateCylinder(height: 0.12, radius: 0.004), materials: [cord])
        wire.position = [0, Self.hangHeight - 0.04, 0]
        entity.addChild(wire)

        bulb = ModelEntity(mesh: .generateSphere(radius: 0.03), materials: [UnlitMaterial(color: .white)])
        bulb.position = [0, Self.hangHeight - 0.31, 0]
        entity.addChild(bulb)

        light.light.color = NSColor(srgbRed: 1, green: 0.86, blue: 0.66, alpha: 1)
        light.light.intensity = 0
        light.light.innerAngleInDegrees = 35
        light.light.outerAngleInDegrees = 70
        light.light.attenuationRadius = 3.2
        light.position = [0, Self.hangHeight - 0.34, 0]
        light.look(at: [0, 0, 0.001], from: light.position, relativeTo: entity)
        entity.addChild(light)
    }

    /// level: 0 kapalı, 1 tam parlak. Yumuşak açılıp kapanır.
    func tick(level target: Float, dt: Float) {
        level += (target - level) * min(1, dt * 2.5)
        light.light.intensity = level * 9000
        guard abs(level - shownLevel) > 0.02 else { return }
        shownLevel = level
        let warm = NSColor(srgbRed: 1, green: 0.88, blue: 0.62, alpha: 1)
        let off = NSColor(srgbRed: 0.82, green: 0.82, blue: 0.8, alpha: 1)
        bulb.model?.materials = [UnlitMaterial(color: off.blended(withFraction: CGFloat(min(1, level * 1.4)), of: warm) ?? warm)]
    }
}

/// Karakterin üstünde birkaç saniye görünen mesaj/yanıt balonu.
struct SpeechBubble: Equatable {
    enum Kind { case prompt, reply }
    var text: String
    var kind: Kind
    var until: Date
}
