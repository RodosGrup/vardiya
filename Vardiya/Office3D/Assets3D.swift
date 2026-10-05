import Foundation
import RealityKit

/// Kenney modellerini bir kez yükleyip şablon olarak saklar; sahne her seferinde kopyasını alır.
///
/// Modellerin orijinleri tutarsız (kimi köşede, kimi ortada). `prop(_:)` her modeli
/// taban ortası (0, 0, 0) olacak şekilde bir kapsayıcıya koyar, böylece yerleşim kodu
/// "bu masayı şuraya koy" diyebiliyor.
@MainActor
final class Assets3D {
    static let characterNames = ["male", "female"].flatMap { g in "abcdef".map { "character-\(g)-\($0)" } }

    private var templates: [String: Entity] = [:]
    let animations: AnimationLibrary

    private init(animations: AnimationLibrary) {
        self.animations = animations
    }

    static func load() async -> Assets3D {
        let animations = AnimationLibrary.load()
        let assets = Assets3D(animations: animations)
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "usdz", subdirectory: nil) else { return assets }
        for url in urls {
            if let entity = try? await Entity(contentsOf: url) {
                assets.templates[url.deletingPathExtension().lastPathComponent] = entity
            }
        }
        return assets
    }

    /// Tabanı zemine oturan, ayak izi ortalanmış bir mobilya kopyası.
    func prop(_ name: String, scale: Float = 1) -> Entity {
        let holder = Entity()
        holder.name = name
        guard let template = templates[name] else { return holder }
        let model = template.clone(recursive: true)
        model.scale = .init(repeating: scale)
        let bounds = model.visualBounds(relativeTo: nil)
        model.position = [-bounds.center.x, -bounds.min.y, -bounds.center.z]
        holder.addChild(model)
        return holder
    }

    func character(_ index: Int) -> Entity? {
        let name = Self.characterNames[abs(index) % Self.characterNames.count]
        return templates[name]?.clone(recursive: true)
    }
}

// MARK: - Animasyon

/// GLB'den çıkarılmış eklem animasyonları (scripts/build_assets.py → animations.json).
struct AnimationLibrary {
    struct Track {
        var times: [Float]
        var values: [SIMD4<Float>]
        var step: Bool
    }

    struct Clip {
        var duration: Float
        var rotations: [String: Track]
        var translations: [String: Track]
    }

    var clips: [String: Clip] = [:]
    var rest: [String: SIMD3<Float>] = [:]

    static func load() -> AnimationLibrary {
        var lib = AnimationLibrary()
        guard let url = Bundle.main.url(forResource: "animations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return lib }

        for (joint, t) in json["rest"] as? [String: [Double]] ?? [:] where t.count == 3 {
            lib.rest[joint] = SIMD3(Float(t[0]), Float(t[1]), Float(t[2]))
        }
        for (name, raw) in json["clips"] as? [String: [String: Any]] ?? [:] {
            var clip = Clip(duration: Float(raw["duration"] as? Double ?? 1), rotations: [:], translations: [:])
            for (joint, channels) in raw["channels"] as? [String: [String: Any]] ?? [:] {
                for (path, ch) in channels {
                    guard let ch = ch as? [String: Any],
                          let t = ch["t"] as? [Double], let v = ch["v"] as? [[Double]] else { continue }
                    let values = v.map { SIMD4<Float>(Float($0[0]), Float($0[1]), Float($0[2]), $0.count > 3 ? Float($0[3]) : 0) }
                    let track = Track(times: t.map(Float.init), values: values, step: ch["step"] as? Bool ?? false)
                    if path == "rotation" { clip.rotations[joint] = track } else { clip.translations[joint] = track }
                }
            }
            lib.clips[name] = clip
        }
        return lib
    }

    /// Klibin `time` anındaki eklem pozu (döngülü).
    func sample(_ name: String, at time: Float, loop: Bool = true) -> [String: (rotation: simd_quatf?, translation: SIMD3<Float>?)] {
        guard let clip = clips[name] else { return [:] }
        let t: Float
        if clip.duration <= 0 { t = 0 }
        else if loop { t = time.truncatingRemainder(dividingBy: clip.duration) }
        else { t = min(time, clip.duration) }

        var pose: [String: (rotation: simd_quatf?, translation: SIMD3<Float>?)] = [:]
        for (joint, track) in clip.rotations {
            let v = Self.interpolate(track, at: t, slerp: true)
            pose[joint, default: (nil, nil)].rotation = simd_quatf(vector: v)
        }
        for (joint, track) in clip.translations {
            let v = Self.interpolate(track, at: t, slerp: false)
            pose[joint, default: (nil, nil)].translation = SIMD3(v.x, v.y, v.z)
        }
        return pose
    }

    private static func interpolate(_ track: Track, at t: Float, slerp: Bool) -> SIMD4<Float> {
        let times = track.times
        guard let first = times.first, t > first, times.count > 1 else { return track.values[0] }
        guard let next = times.firstIndex(where: { $0 >= t }) else { return track.values[track.values.count - 1] }
        let prev = next - 1
        if track.step { return track.values[prev] }
        let span = times[next] - times[prev]
        let f = span > 0 ? (t - times[prev]) / span : 0
        if slerp {
            return simd_slerp(simd_quatf(vector: track.values[prev]), simd_quatf(vector: track.values[next]), f).vector
        }
        return track.values[prev] + (track.values[next] - track.values[prev]) * f
    }
}
