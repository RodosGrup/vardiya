import SwiftUI

/// Ofisin geometrisi: zemin, masalar, sandalyeler, karakterler ve aktarım çizgileri.
/// Yazılar ve tıklanabilir balonlar SwiftUI katmanında (OfficeView) duruyor.
struct OfficeCanvas: View {
    let layout: OfficeLayout
    let placed: [PlacedWorker]
    let selectedID: String?
    let iso: Iso

    var body: some View {
        // Animasyon yalnızca biri çalışıyorsa akıyor; herkes boştaysa saniyede bir çizim yeter.
        let anyBusy = placed.contains { $0.worker.activity.isBusy || $0.worker.activity.needsYou }
        TimelineView(.animation(minimumInterval: anyBusy ? 1.0 / 30 : 1, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, _ in
                drawFloor(&ctx)
                drawHandoffs(&ctx, t: t)
                if let selected = placed.first(where: { $0.id == selectedID }) {
                    drawSelection(&ctx, seat: selected.seat)
                }
                // Uzaktan yakına (x+y küçükten büyüğe) çiz ki öndekiler arkadakileri örtsün.
                for p in placed.sorted(by: { $0.seat.x + $0.seat.y < $1.seat.x + $1.seat.y }) {
                    drawStation(&ctx, p, t: t)
                }
            }
        }
    }

    // MARK: Zemin

    private func drawFloor(_ ctx: inout GraphicsContext) {
        let pad = 0.5
        let w = layout.width + pad * 2, d = layout.depth + pad * 2
        iso.fillBox(&ctx, x: -pad, y: -pad, z: -0.25, w: w, d: d, h: 0.25,
                    top: Theme.floorTop, left: Theme.floorSideLeft, right: Theme.floorSideRight)

        var grid = Path()
        var i = 0.0
        while i <= layout.width {
            grid.move(to: iso.p(i, -pad)); grid.addLine(to: iso.p(i, layout.depth + pad))
            i += 1
        }
        i = 0
        while i <= layout.depth {
            grid.move(to: iso.p(-pad, i)); grid.addLine(to: iso.p(layout.width + pad, i))
            i += 1
        }
        ctx.stroke(grid, with: .color(Theme.floorGrid), lineWidth: 0.7)

        // Her oturumun alanını hafif bir halıyla ayır.
        for pod in 0..<layout.count {
            let o = layout.podOrigin(pod)
            let e = OfficeLayout.podSize - 0.3
            let rug = iso.quad(iso.p(o.x + 0.3, o.y + 0.3), iso.p(o.x + e, o.y + 0.3),
                               iso.p(o.x + e, o.y + e), iso.p(o.x + 0.3, o.y + e))
            ctx.fill(rug, with: .color(Theme.accent.opacity(0.035)))
            ctx.stroke(rug, with: .color(Theme.accent.opacity(0.12)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 4]))
        }
    }

    private func drawSelection(_ ctx: inout GraphicsContext, seat: (x: Double, y: Double)) {
        let r = iso.quad(iso.p(seat.x - 1.15, seat.y - 1.55), iso.p(seat.x + 1.15, seat.y - 1.55),
                         iso.p(seat.x + 1.15, seat.y + 0.75), iso.p(seat.x - 1.15, seat.y + 0.75))
        ctx.fill(r, with: .color(Theme.accent.opacity(0.08)))
        ctx.stroke(r, with: .color(Theme.accent), lineWidth: 1.8)
    }

    /// Ana ajandan alt ajanlara giden kesikli iş aktarım çizgileri.
    private func drawHandoffs(_ ctx: inout GraphicsContext, t: Double) {
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) })
        for sub in placed {
            guard let parentID = sub.parentID, let main = byID[parentID] else { continue }
            let active = sub.worker.activity.isBusy
            var path = Path()
            let from = iso.p(main.seat.x + 0.8, main.seat.y + 0.1, 0.01)
            let to = iso.p(sub.seat.x - 0.8, sub.seat.y - 0.1, 0.01)
            path.move(to: from)
            path.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2, y: max(from.y, to.y) + 8))
            let color = active ? Theme.accent : (sub.worker.activity == .done ? Theme.success : Theme.muted)
            ctx.stroke(path, with: .color(color.opacity(active ? 0.9 : 0.5)),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [5, 5],
                                          dashPhase: active ? CGFloat(-t * 18) : 0))
        }
    }

    // MARK: Masa ve çalışan

    private func drawStation(_ ctx: inout GraphicsContext, _ p: PlacedWorker, t: Double) {
        let (cx, cy) = p.seat
        let a = p.worker.activity
        // Sandalye, karakter ve laptop aynı x ekseninde: karakter masanın arkasında (y−),
        // yüzü ve kolları masaya (y+) dönük.
        let personY = cy - 0.62
        // Her karakterin animasyonu biraz farklı fazda olsun, hep birlikte sallanmasınlar.
        let t = t + Double(abs(p.id.hashValue % 1000)) / 159

        drawChair(&ctx, x: cx, y: personY)
        drawBody(&ctx, x: cx, y: personY, activity: a, t: t, headset: !p.isSubagent)

        // Masa: ince tabla + bacaklar
        let w = 1.5, d = 0.75, top = 0.42
        let x0 = cx - w / 2, y0 = cy - d / 2
        var legs = Path()
        for (lx, ly) in [(x0 + 0.06, y0 + 0.06), (x0 + w - 0.06, y0 + 0.06), (x0 + 0.06, y0 + d - 0.06), (x0 + w - 0.06, y0 + d - 0.06)] {
            legs.move(to: iso.p(lx, ly, top)); legs.addLine(to: iso.p(lx, ly, 0))
        }
        ctx.stroke(legs, with: .color(Theme.deskEdge), lineWidth: 1.4)
        iso.fillBox(&ctx, x: x0, y: y0, z: top - 0.05, w: w, d: d, h: 0.05,
                    top: Theme.deskTop, left: Theme.deskSide, right: Theme.deskEdge.opacity(0.7), edge: Theme.deskEdge.opacity(0.8))

        drawLaptopBase(&ctx, cx: cx, cy: cy, z: top)
        // Eller masanın üstünde olduğu için masadan sonra, kapaktan önce çiziliyor.
        drawHands(&ctx, x: cx, y: personY, activity: a, t: t)
        drawLaptopLid(&ctx, cx: cx, cy: cy, z: top, activity: a, t: t)
        drawProps(&ctx, cx: cx, cy: cy, z: top, activity: a, t: t)
        if a.needsYou { drawAlert(&ctx, x: cx, y: personY, t: t) }
    }

    private func drawChair(_ ctx: inout GraphicsContext, x: Double, y: Double) {
        var leg = Path()
        leg.move(to: iso.p(x, y, 0.26)); leg.addLine(to: iso.p(x, y, 0.02))
        ctx.stroke(leg, with: .color(Theme.deskEdge), lineWidth: 1.5)
        // Oturak ve arkalık; arkalık karakterin arkasında (y−) kalıyor.
        iso.fillBox(&ctx, x: x - 0.24, y: y - 0.22, z: 0.26, w: 0.48, d: 0.44, h: 0.06,
                    top: Theme.chair, left: Theme.deskSide, right: Theme.deskEdge.opacity(0.6))
        iso.fillBox(&ctx, x: x - 0.24, y: y - 0.3, z: 0.32, w: 0.48, d: 0.07, h: 0.5,
                    top: Theme.chair, left: Theme.chair, right: Theme.deskSide)
    }

    private func personColor(_ a: Activity) -> Color {
        a.isBusy || a.needsYou ? Theme.person : Theme.personIdle
    }

    /// Yumuşak, videodaki gibi yuvarlak omuzlu bir gövde. Yön duygusunu kollar ve
    /// karakterle aynı eksendeki laptop veriyor; gövdenin alt yarısını kapak örtüyor.
    private func drawBody(_ ctx: inout GraphicsContext, x: Double, y: Double, activity a: Activity, t: Double, headset: Bool) {
        let s = iso.scale
        let color = personColor(a)
        let (by, bob) = posture(y: y, activity: a, t: t)

        let base = iso.p(x, by, 0.36)
        let w = 0.48 * s, h = 0.46 * s + bob * s
        let torsoRect = CGRect(x: base.x - w / 2, y: base.y - h, width: w, height: h)
        let torso = UnevenRoundedRectangle(topLeadingRadius: w * 0.42, bottomLeadingRadius: w * 0.12,
                                           bottomTrailingRadius: w * 0.12, topTrailingRadius: w * 0.42)
            .path(in: torsoRect)
        ctx.fill(torso, with: .color(color))
        // Sağ yanı hafif gölgeli: ışık sol üstten geliyor, gövde düz bir leke gibi durmuyor.
        var shade = ctx
        shade.clip(to: torso)
        shade.fill(Path(CGRect(x: base.x + w * 0.18, y: torsoRect.minY, width: w, height: h)), with: .color(.black.opacity(0.14)))

        let head = iso.p(x, by, 1.05 + bob)
        let r = 0.15 * s
        let headRect = CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: headRect), with: .color(color))
        var headShade = ctx
        headShade.clip(to: Path(ellipseIn: headRect))
        headShade.fill(Path(CGRect(x: head.x + r * 0.35, y: head.y - r, width: r, height: r * 2)), with: .color(.black.opacity(0.12)))

        // Ana ajanlarda kulaklık
        if headset {
            var band = Path()
            band.addArc(center: head, radius: r * 1.2, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
            ctx.stroke(band, with: .color(Theme.device), lineWidth: max(1.5, 0.035 * s))
            for side in [-1.0, 1.0] {
                let e = CGRect(x: head.x + side * r * 1.1 - 0.05 * s, y: head.y - 0.06 * s, width: 0.1 * s, height: 0.14 * s)
                ctx.fill(Path(roundedRect: e, cornerRadius: 0.03 * s), with: .color(Theme.device))
            }
        }
    }

    /// Çalışırken masaya doğru eğilip hafifçe sallanır, boştayken arkasına yaslanır.
    private func posture(y: Double, activity a: Activity, t: Double) -> (y: Double, bob: Double) {
        a.isBusy ? (y + 0.05, sin(t * 3) * 0.012) : (y - 0.03, 0)
    }

    /// Kollar ve eller masanın üstünde kaldığı için masadan sonra çiziliyor.
    private func drawHands(_ ctx: inout GraphicsContext, x: Double, y: Double, activity a: Activity, t: Double) {
        let s = iso.scale
        let color = personColor(a)
        let (by, bob) = posture(y: y, activity: a, t: t)
        let shoulderZ = 0.36 + 0.46 * 0.72 + bob
        let arm = StrokeStyle(lineWidth: 0.1 * s, lineCap: .round)
        let hr = 0.055 * s

        for side in [-1.0, 1.0] {
            // Omuz, gövdenin ekrandaki kenarına yakın bir noktadan çıkıyor.
            var shoulder = iso.p(x, by, shoulderZ)
            shoulder.x += CGFloat(side) * 0.17 * s
            let tap = a.isBusy ? max(0, sin(t * 14 + side * 1.6)) * 0.03 : 0
            let hand = a.isBusy
                ? iso.p(x + side * 0.13, by + 0.4, 0.46 + tap)   // klavyede
                : iso.p(x + side * 0.15, by + 0.3, 0.44)          // masada, dinleniyor
            var path = Path()
            path.move(to: shoulder)
            path.addLine(to: hand)
            ctx.stroke(path, with: .color(color), style: arm)
            ctx.fill(Path(ellipseIn: CGRect(x: hand.x - hr, y: hand.y - hr, width: hr * 2, height: hr * 2)), with: .color(color))
        }
    }

    /// Size ihtiyacı olduğunda kafasının üstünde nabız gibi atan ünlem.
    private func drawAlert(_ ctx: inout GraphicsContext, x: Double, y: Double, t: Double) {
        let s = iso.scale
        let pulse = 1 + 0.15 * sin(t * 5)
        let c = iso.p(x, y, 1.5)
        let pr = 0.13 * s * pulse
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - pr, y: c.y - pr, width: pr * 2, height: pr * 2)), with: .color(Theme.warning))
        ctx.draw(Text("!").font(.system(size: 0.18 * s, weight: .heavy)).foregroundStyle(.white), at: c)
    }

    // Laptop karakterle aynı eksende, masanın arka yarısında; klavye karaktere yakın,
    // menteşe uzak kenarda. Ekran karaktere dönük, izleyici kapağın arkasını görüyor.
    private static let laptop = (w: 0.56, d: 0.3, back: 0.3)

    private func drawLaptopBase(_ ctx: inout GraphicsContext, cx: Double, cy: Double, z: Double) {
        let l = Self.laptop
        iso.fillBox(&ctx, x: cx - l.w / 2, y: cy - l.back, z: z, w: l.w, d: l.d, h: 0.025,
                    top: Theme.device.opacity(0.85), left: Theme.device, right: Theme.device)
    }

    private func drawLaptopLid(_ ctx: inout GraphicsContext, cx: Double, cy: Double, z: Double, activity a: Activity, t: Double) {
        let l = Self.laptop
        let x0 = cx - l.w / 2, x1 = cx + l.w / 2
        let hinge = cy - l.back + l.d
        let lid = iso.quad(iso.p(x0, hinge, z + 0.025), iso.p(x1, hinge, z + 0.025),
                           iso.p(x1, hinge + 0.08, z + 0.42), iso.p(x0, hinge + 0.08, z + 0.42))
        ctx.fill(lid, with: .color(Theme.device))
        // Arkadaki logo ışığı: çalışırken mavi yanar.
        let glow = iso.p(cx, hinge + 0.04, z + 0.23)
        let gr = 0.035 * iso.scale
        let on = a.isBusy ? 0.6 + 0.4 * sin(t * 4) : 0.25
        ctx.fill(Path(ellipseIn: CGRect(x: glow.x - gr, y: glow.y - gr, width: gr * 2, height: gr * 2)),
                 with: .color((a.isBusy ? Theme.accent : Theme.muted).opacity(on)))
    }

    /// Masadaki küçük ipuçları: yazarken uçan kâğıtlar, boştayken kahve.
    private func drawProps(_ ctx: inout GraphicsContext, cx: Double, cy: Double, z: Double, activity a: Activity, t: Double) {
        let s = iso.scale
        switch a {
        case .writing, .reading:
            // Masanın sağında yükselip kaybolan sayfalar
            for k in 0..<2 {
                let cycle = (t * 0.5 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                let rise = cycle * 0.5
                let c = iso.p(cx - 0.55, cy + 0.05, z + 0.12 + rise)
                drawSheet(&ctx, at: c, size: 0.28 * s, opacity: 1 - cycle)
            }
            drawSheet(&ctx, at: iso.p(cx - 0.55, cy + 0.1, z + 0.08), size: 0.28 * s, opacity: 1)
        case .running:
            // Komut çalışırken sağda küçük bir sunucu kutusu yanıp söner.
            iso.fillBox(&ctx, x: cx - 0.72, y: cy - 0.15, z: z, w: 0.3, d: 0.25, h: 0.18,
                        top: Theme.device.opacity(0.8), left: Theme.device, right: Theme.device.opacity(0.9))
            let led = iso.p(cx - 0.57, cy + 0.1, z + 0.09)
            let on = sin(t * 9) > 0
            ctx.fill(Path(ellipseIn: CGRect(x: led.x - 2, y: led.y - 2, width: 4, height: 4)),
                     with: .color(on ? Theme.success : Theme.success.opacity(0.3)))
        case .idle:
            // Kahve fincanı ve buharı: "sıra sizde, ajan bekliyor".
            let base = iso.p(cx - 0.55, cy + 0.12, z)
            let cw = 0.13 * s, ch = 0.14 * s
            ctx.fill(Path(roundedRect: CGRect(x: base.x - cw / 2, y: base.y - ch, width: cw, height: ch), cornerRadius: 2),
                     with: .color(Theme.chair))
            ctx.stroke(Path(roundedRect: CGRect(x: base.x - cw / 2, y: base.y - ch, width: cw, height: ch), cornerRadius: 2),
                       with: .color(Theme.deskEdge), lineWidth: 0.8)
            for k in 0..<2 {
                var steam = Path()
                let sx = base.x - cw * 0.2 + CGFloat(k) * cw * 0.4
                let drift = sin(t * 1.5 + Double(k)) * 2
                steam.move(to: CGPoint(x: sx, y: base.y - ch - 2))
                steam.addQuadCurve(to: CGPoint(x: sx + drift, y: base.y - ch - 0.2 * s),
                                   control: CGPoint(x: sx + 4, y: base.y - ch - 0.1 * s))
                ctx.stroke(steam, with: .color(Theme.muted.opacity(0.5)), lineWidth: 1)
            }
        case .done:
            drawSheet(&ctx, at: iso.p(cx - 0.55, cy + 0.1, z + 0.02), size: 0.28 * s, opacity: 1, check: true)
        default:
            break
        }
    }

    private func drawSheet(_ ctx: inout GraphicsContext, at c: CGPoint, size: CGFloat, opacity: Double, check: Bool = false) {
        guard opacity > 0.02 else { return }
        var layer = ctx
        layer.opacity = opacity
        let rect = CGRect(x: c.x - size / 2, y: c.y - size * 0.65, width: size, height: size * 0.75)
        let sheet = Path(roundedRect: rect, cornerRadius: 2)
        layer.fill(sheet, with: .color(Theme.card))
        layer.stroke(sheet, with: .color(Theme.deskEdge), lineWidth: 0.8)
        for k in 0..<3 {
            var line = Path()
            let ly = rect.minY + rect.height * (0.28 + CGFloat(k) * 0.22)
            line.move(to: CGPoint(x: rect.minX + size * 0.15, y: ly))
            line.addLine(to: CGPoint(x: rect.maxX - size * (k == 2 ? 0.4 : 0.15), y: ly))
            layer.stroke(line, with: .color(check ? Theme.success.opacity(0.7) : Theme.muted.opacity(0.6)), lineWidth: 1)
        }
    }
}
