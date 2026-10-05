import AppKit
import RealityKit
import SwiftUI

/// 3D ofis görünümü: RealityKit sahnesi + üstünde SwiftUI balonları.
struct Office3DView: View {
    @Environment(ShiftStore.self) private var store
    @State private var world = OfficeWorld()
    @State private var subscription: EventSubscription?
    @State private var dragging = false
    @State private var scrollMonitor: Any?
    @State private var hovering = false
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
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { v in
                            world.orbit(translation: v.translation, began: !dragging)
                            dragging = true
                        }
                        .onEnded { _ in
                            dragging = false
                            world.endOrbit()
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture().onChanged { v in
                        world.zoom(by: Float(1 / max(0.5, min(1.5, v.magnification))) * 0.98 + 0.02)
                    }
                )
                .onContinuousHover { phase in
                    if case .active = phase { hovering = true } else { hovering = false }
                }

                if world.isReady {
                    OverlayLayer(world: world)
                        .allowsHitTesting(true)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear { world.viewport = geo.size; installScroll() }
            .onChange(of: geo.size) { _, size in world.viewport = size }
            .onDisappear { removeScroll() }
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

    /// Fare tekerleği / iki parmak kaydırma ile yakınlaştırma.
    private func installScroll() {
        guard scrollMonitor == nil else { return }
        let world = world
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard hovering else { return event }
            let delta = Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
            world.zoom(by: exp(-delta))
            return nil
        }
    }

    private func removeScroll() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
    }
}

private struct CameraControls: View {
    let world: OfficeWorld

    var body: some View {
        HStack(spacing: 6) {
            Button { world.zoom(by: 0.85) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { world.zoom(by: 1.18) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { world.frameAll() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help(Text("Show whole office"))
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
