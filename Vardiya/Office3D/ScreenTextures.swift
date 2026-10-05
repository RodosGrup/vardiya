import AppKit
import RealityKit

/// Monitör ekranlarının kare kare görüntüleri. Bir kez üretilip bütün masalarca paylaşılır;
/// ekran, ajanın durumuna göre bu kareler arasında döner.
@MainActor
enum ScreenTextures {
    enum Reel { case code, document, cursor, image }

    static let frameCount = 12
    private static var cache: [Reel: [TextureResource]] = [:]

    static func frames(_ reel: Reel) -> [TextureResource] {
        if let cached = cache[reel] { return cached }
        let made = (0..<frameCount).compactMap { i -> TextureResource? in
            guard let image = render(reel, frame: i) else { return nil }
            return try? TextureResource(image: image, options: .init(semantic: .color))
        }
        cache[reel] = made
        return made
    }

    private static let width = 192, height = 120

    /// Sabit tohumlu sözde rastgele: her açılışta aynı "kod" görünsün.
    private static func noise(_ n: Int) -> Double {
        let x = sin(Double(n) * 12.9898) * 43758.5453
        return x - floor(x)
    }

    private static func render(_ reel: Reel, frame: Int) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CG'de y yukarı; satırları yukarıdan aşağı çizmek için çeviriyoruz.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        let lineH: CGFloat = 9
        let rows = Int(CGFloat(height) / lineH) + 2

        switch reel {
        case .code:
            ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.07, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let palette = [
                CGColor(srgbRed: 0.24, green: 0.86, blue: 0.42, alpha: 1),  // yeşil
                CGColor(srgbRed: 0.35, green: 0.8, blue: 0.95, alpha: 1),   // camgöbeği
                CGColor(srgbRed: 0.75, green: 0.55, blue: 1, alpha: 1),     // mor
                CGColor(srgbRed: 0.95, green: 0.8, blue: 0.4, alpha: 1),    // sarı
            ]
            // Her karede bir satır yukarı kayar; yeni satır altta yazılıyor gibi görünür.
            for r in 0..<rows {
                let line = r + frame
                let y = CGFloat(r) * lineH + 5
                let indent = CGFloat(Int(noise(line * 7) * 4)) * 10 + 8
                var x = indent
                let tokens = 1 + Int(noise(line * 13) * 4)
                for t in 0..<tokens {
                    let w = 10 + noise(line * 31 + t * 5) * 34
                    let color = t == 0 ? palette[0] : palette[Int(noise(line * 17 + t) * Double(palette.count)) % palette.count]
                    ctx.setFillColor(color)
                    ctx.fill(CGRect(x: x, y: y, width: CGFloat(w), height: 4))
                    x += CGFloat(w) + 5
                    if x > CGFloat(width) - 20 { break }
                }
            }
            // Son satırda yanıp sönen imleç
            if frame % 2 == 0 {
                ctx.setFillColor(palette[0])
                ctx.fill(CGRect(x: 8, y: CGFloat(height) - 12, width: 6, height: 7))
            }
        case .document:
            ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.95, blue: 0.97, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.62, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: 10))
            for r in 0..<rows {
                let line = r + frame / 2
                let y = CGFloat(r) * lineH + 16
                let w = 60 + noise(line * 11) * 110
                let shade = line % 6 == 0 ? 0.25 : 0.6
                ctx.setFillColor(CGColor(srgbRed: shade, green: shade, blue: shade + 0.05, alpha: 1))
                ctx.fill(CGRect(x: 10, y: y, width: CGFloat(w), height: 3.5))
            }
        case .image:
            // Görüntüleyici: koyu çerçeve içinde gökyüzü, tepe ve güneş; üstünde gezinen inceleme kutusu
            ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let photo = CGRect(x: 14, y: 10, width: CGFloat(width) - 28, height: CGFloat(height) - 20)
            ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.78, blue: 0.98, alpha: 1))
            ctx.fill(photo)
            ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.7, blue: 0.4, alpha: 1))
            ctx.fill(CGRect(x: photo.minX, y: photo.midY + 8, width: photo.width, height: photo.height / 2 - 8))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.35, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: photo.maxX - 40, y: photo.minY + 10, width: 20, height: 20))
            // İnceleme kutusu karelere göre resim üzerinde dolaşır
            let fx = CGFloat(noise(frame * 3)) * (photo.width - 50) + photo.minX
            let fy = CGFloat(noise(frame * 5 + 1)) * (photo.height - 34) + photo.minY
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
            ctx.setLineWidth(2)
            ctx.stroke(CGRect(x: fx, y: fy, width: 50, height: 34))
        case .cursor:
            ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.07, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(srgbRed: 0.24, green: 0.86, blue: 0.42, alpha: 0.5))
            ctx.fill(CGRect(x: 8, y: 6, width: 30, height: 4))
            if frame % 4 < 2 {
                ctx.setFillColor(CGColor(srgbRed: 0.24, green: 0.86, blue: 0.42, alpha: 1))
                ctx.fill(CGRect(x: 42, y: 5, width: 6, height: 7))
            }
        }
        return ctx.makeImage()
    }
}
