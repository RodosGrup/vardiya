import AppKit
import RealityKit
import SwiftUI

/// 3D ofis görünümü: RealityKit sahnesi + üstünde SwiftUI balonları.
struct Office3DView: View {
    @Environment(ShiftStore.self) private var store
    @State private var world = OfficeWorld()
    @State private var subscription: EventSubscription?
    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnify: CGFloat = 1
    @State private var lastRotation: Angle = .zero
    @State private var eventMonitor: Any?
    @State private var hovering = false
    @State private var hoverPoint: CGPoint?
    /// 3D alanın pencere içindeki yeri; fare olaylarının sahnenin üstünde olup olmadığını buradan anlıyoruz.
    @State private var sceneFrame: CGRect = .zero
    /// Sağ/orta tuşla sürüklemede bir önceki fare konumu (pencere koordinatı).
    @State private var lastDragPoint: CGPoint?
    /// Sahnenin bulunduğu pencere; sohbet gibi başka pencerelerdeki kaydırmalar sahneyi oynatmasın.
    @State private var hostWindow = WeakWindow()
    /// RealityView'u yeniden kurmak için. Pencere başka bir pencerenin arkasında açıldığında
    /// çizim hiç başlamayabiliyor; o durumda sahne birkaç saniye kare üretmezse görünümü tazeliyoruz.
    @State private var renderKey = 0
    private let watchdog = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RealityView { content in
                    content.add(world.root)
                    await world.setup()
                    world.sync(store.shifts)
                    let world = world
                    subscription = content.subscribe(to: SceneEvents.Update.self) { event in
                        MainActor.assumeIsolated { world.tick(Float(event.deltaTime)) }
                    }
                }
                .id(renderKey)
                .gesture(
                    SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                        world.tapped(value.entity)
                    }
                )
                // Boş alana çift tık: tüm ofis
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { _ in world.frameAll() })
                // Sürükle: döndür; ⌥ ile sürükle: kaydır
                .simultaneousGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { v in
                            let delta = CGSize(width: v.translation.width - lastDrag.width,
                                               height: v.translation.height - lastDrag.height)
                            lastDrag = v.translation
                            let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                            if flags.contains(.option) {
                                world.pan(by: delta)
                            } else {
                                world.orbit(by: delta)
                            }
                        }
                        .onEnded { _ in lastDrag = .zero }
                )
                // Kıstır: yakınlaş. Değer hareketin başından beri toplam; farkını uyguluyoruz.
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            let step = lastMagnify / max(0.01, v.magnification)
                            lastMagnify = v.magnification
                            world.zoom(by: Float(step), at: hoverPoint)
                        }
                        .onEnded { _ in lastMagnify = 1 }
                )
                // İki parmakla çevir: döndür
                .simultaneousGesture(
                    RotateGesture()
                        .onChanged { v in
                            world.rotate(by: Float((v.rotation - lastRotation).radians))
                            lastRotation = v.rotation
                        }
                        .onEnded { _ in lastRotation = .zero }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hovering = true; hoverPoint = p
                    case .ended: hovering = false; hoverPoint = nil
                    }
                }

                if world.isReady {
                    OverlayLayer(world: world)
                        .allowsHitTesting(true)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(WindowReader(holder: hostWindow))
            .onAppear { world.viewport = geo.size; sceneFrame = geo.frame(in: .global); installMonitors() }
            .onChange(of: geo.size) { _, size in world.viewport = size; sceneFrame = geo.frame(in: .global) }
            .onDisappear { removeMonitors() }
        }
        .onChange(of: store.shifts) { _, shifts in world.sync(shifts) }
        .onReceive(watchdog) { _ in
            guard world.isReady, Date.now.timeIntervalSince(world.lastTickAt) > 4,
                  NSApp.windows.contains(where: { $0.isVisible && $0.occlusionState.contains(.visible) }) else { return }
            renderKey += 1
        }
        .onChange(of: store.selectedWorkerID, initial: true) { _, id in world.selectedID = id }
        .onAppear {
            world.onSelect = { id in store.selectedWorkerID = id }
        }
        .overlay(alignment: .bottomTrailing) {
            CameraControls(world: world)
                .padding(14)
        }
    }

    /// Trackpad'de iki parmak kaydırma = kaydır (⌘ ile yakınlaş); fare tekerleği = imlece doğru yakınlaş;
    /// sağ ya da orta tuşla sürükleme = kaydır.
    private func installMonitors() {
        guard eventMonitor == nil else { return }
        let world = world
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .rightMouseDown, .otherMouseDown, .rightMouseDragged, .otherMouseDragged]) { event in
            if event.type == .rightMouseDown || event.type == .otherMouseDown {
                lastDragPoint = event.locationInWindow
                return event
            }
            // Olay ana pencereden mi ve 3D alanın üstünde mi? (SwiftUI global koordinatı = pencere, üstten aşağı)
            guard let window = event.window, window === hostWindow.window,
                  let content = window.contentView else { return event }
            let p = event.locationInWindow
            let local = CGPoint(x: p.x, y: content.bounds.height - p.y)
            guard sceneFrame.contains(local) else { return event }
            let point = CGPoint(x: local.x - sceneFrame.minX, y: local.y - sceneFrame.minY)
            switch event.type {
            case .scrollWheel:
                if event.hasPreciseScrollingDeltas, !event.modifierFlags.contains(.command) {
                    world.pan(by: CGSize(width: -event.scrollingDeltaX, height: -event.scrollingDeltaY))
                } else {
                    let delta = Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.006 : 0.05)
                    world.zoom(by: exp(-delta), at: point)
                }
            default:
                // Olayın kendi delta'sı her zaman dolu gelmiyor; konum farkından hesaplıyoruz.
                let now = event.locationInWindow
                let prev = lastDragPoint ?? now
                lastDragPoint = now
                world.pan(by: CGSize(width: now.x - prev.x, height: prev.y - now.y))
            }
            return nil
        }
    }

    private func removeMonitors() {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        eventMonitor = nil
    }
}

/// Görünümün içinde bulunduğu NSWindow'u yakalar.
final class WeakWindow {
    weak var window: NSWindow?
}

private struct WindowReader: NSViewRepresentable {
    let holder: WeakWindow

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { holder.window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if holder.window == nil { DispatchQueue.main.async { holder.window = view.window } }
    }
}

private struct CameraControls: View {
    let world: OfficeWorld
    @State private var showHelp = false

    var body: some View {
        HStack(spacing: 6) {
            Button { world.zoom(by: 0.8) } label: { Image(systemName: "plus.magnifyingglass") }
                .help(Text("Zoom in"))
            Button { world.zoom(by: 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help(Text("Zoom out"))
            Divider().frame(height: 14)
            Menu {
                Button("Isometric") { world.preset(.isometric) }
                Button("Top down") { world.preset(.top) }
                Button("Front") { world.preset(.front) }
            } label: {
                Image(systemName: "camera.viewfinder")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Camera angle"))
            Button { world.frameAll() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help(Text("Show whole office"))
            Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                .popover(isPresented: $showHelp, arrowEdge: .top) { CameraHelp() }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border) }
    }
}

/// Kamera kısayolları
private struct CameraHelp: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            row("Drag", "Rotate")
            row("⌥ Drag · Right drag", "Pan")
            row("Two-finger scroll", "Pan")
            row("Pinch · Mouse wheel · ⌘ Scroll", "Zoom toward the cursor")
            row("Two-finger rotate", "Rotate")
            row("Click an agent", "Follow the agent")
            row("Double-click", "Show whole office")
        }
        .font(.system(size: 12))
        .padding(14)
    }

    private func row(_ gesture: LocalizedStringKey, _ action: LocalizedStringKey) -> some View {
        GridRow {
            Text(gesture).foregroundStyle(Theme.textSecondary)
            Text(action).foregroundStyle(Theme.text)
        }
    }
}

/// Balonlar: durum, konuşma (mesaj/yanıt) ve token rozetleri. Uzaktakiler biraz küçülür.
private struct OverlayLayer: View {
    @Environment(ShiftStore.self) private var store
    let world: OfficeWorld

    var body: some View {
        let workers = Dictionary(store.shifts.flatMap(\.workers).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        ZStack(alignment: .topLeading) {
            ForEach(world.anchors.sorted(by: { $0.value.depth > $1.value.depth }), id: \.key) { id, anchor in
                if let censor = anchor.censor {
                    CensorBox(depth: anchor.depth)
                        .position(censor)
                }
                if let worker = workers[id] {
                    let scale = CGFloat(max(0.72, min(1.05, 9 / anchor.depth)))
                    TokenChip(worker: worker)
                        .scaleEffect(scale)
                        .position(anchor.desk)
                    VStack(spacing: 4) {
                        if let mood = anchor.mood {
                            MoodBubble(text: mood)
                                .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
                        }
                        if let bubble = world.speech[id] {
                            SpeechView(bubble: bubble)
                                .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                        }
                        StatusBubble(worker: worker, isSelected: id == store.selectedWorkerID, note: anchor.note)
                            .onTapGesture {
                                store.selectedWorkerID = id
                                world.focus(on: id)
                            }
                    }
                    .scaleEffect(scale, anchor: .bottom)
                    .fixedSize()
                    .alignmentGuide(.bottom) { $0[.bottom] }
                    .position(x: anchor.head.x, y: anchor.head.y - 22 * scale)
                    .animation(.snappy, value: world.speech[id])
                    .animation(.bouncy, value: anchor.mood == nil)
                }
            }
        }
    }
}

/// Lavabodaki ajanın üstüne gelen pikselli sansür kutusu 😄
private struct CensorBox: View {
    let depth: Float

    var body: some View {
        let size = CGFloat(max(34, min(70, 300 / depth)))
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let seed = Int(context.date.timeIntervalSinceReferenceDate * 4)
            Canvas { ctx, canvas in
                let n = 6
                let cell = canvas.width / CGFloat(n)
                for i in 0..<n {
                    for j in 0..<n {
                        // Her çeyrek saniyede karışan gri-ten tonlu mozaik
                        let v = Double((i * 7 + j * 13 + seed * 5) % 9) / 9
                        let color = Color(red: 0.55 + v * 0.35, green: 0.45 + v * 0.3, blue: 0.42 + v * 0.3)
                        ctx.fill(Path(CGRect(x: CGFloat(i) * cell, y: CGFloat(j) * cell, width: cell + 0.5, height: cell + 0.5)), with: .color(color))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .allowsHitTesting(false)
    }
}

/// Çizgi roman tarzı sinir balonu; hafifçe titrer.
private struct MoodBubble: View {
    let text: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Text(text)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.85, green: 0.15, blue: 0.12))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color(red: 1, green: 0.95, blue: 0.9), in: Capsule())
                .overlay { Capsule().strokeBorder(Color(red: 0.85, green: 0.15, blue: 0.12), lineWidth: 1.5) }
                .rotationEffect(.degrees(sin(t * 30) * (text.hasPrefix("🤬🤬") ? 3 : 1.5)))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .fixedSize()
        .allowsHitTesting(false)
    }
}

private struct SpeechView: View {
    let bubble: SpeechBubble

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: bubble.kind == .prompt ? "envelope.fill" : "text.bubble.fill")
                .font(.system(size: 10))
                .foregroundStyle(bubble.kind == .prompt ? Theme.accent : Theme.success)
                .padding(.top, 1)
            Text(bubble.text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text)
                .lineLimit(3)
                .frame(maxWidth: 230, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(bubble.kind == .prompt ? Theme.accent.opacity(0.5) : Theme.success.opacity(0.5))
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}
