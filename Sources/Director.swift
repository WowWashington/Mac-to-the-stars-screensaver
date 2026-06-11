import Foundation
import simd

// Deterministic, seedable RNG so each run of the saver is a fresh universe.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(state: UInt64) { self.state = state == 0 ? 0x9E3779B97F4A7C15 : state }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum SceneKind: Int32 {
    case cruise = 0, galaxy = 1, planet = 2, warp = 3, encounter = 4, deepfield = 5
}

struct SceneSpec {
    var kind: SceneKind
    var params: SIMD4<Float>        // seed, subtype, flags, duration
    var palette: SIMD4<Float>
    var sector: String = ""
    var target: String = ""
}

/// Schedules an endless itinerary: a "region" of space (shared palette) holds
/// 2-3 scenes (cruise / galaxy approach / planet flyby), then a warp jump
/// carries us to the next region with a new palette and fresh seeds.
final class Director {
    private var rng: SplitMix64
    private var current: SceneSpec
    private var previous: SceneSpec
    private var sceneStart: Double = 0
    private var prevSceneStart: Double = 0
    private var transitionLength: Double = 0.01
    private var queue: [SceneSpec] = []
    /// aspect (w/h) of each bundled NASA seed image; empty = no deepfield scenes
    private let imageAspects: [Float]

    init(seed: UInt64 = .random(in: .min ... .max), imageAspects: [Float] = []) {
        self.imageAspects = imageAspects
        var r = SplitMix64(state: seed)
        // opening palette: classic Milky Way blues/silvers
        var pal = Director.makePalette(&r)
        pal.x = 0.62
        pal.y = 0.55
        // the show opens on a Milky Way-style galaxy seen from outside,
        // growing from a dot as we fly in
        var first = Director.makeScene(.galaxy, palette: pal, rng: &r)
        first.params.w = Float.random(in: 34...42, using: &r)   // a longer, statelier opening
        first.sector = "ORION SPUR · MILKY WAY"
        first.target = "SPIRAL GALAXY · HOME"
        rng = r
        current = first
        previous = first
        queue = makeRegionTail(palette: pal, sector: first.sector)
    }

    // MARK: scene construction

    private static func makePalette(_ r: inout SplitMix64) -> SIMD4<Float> {
        let base = Float.random(in: 0...1, using: &r)
        var accent = base + Float.random(in: 0.18...0.45, using: &r) * (Bool.random(using: &r) ? 1 : -1)
        accent -= accent.rounded(.down)
        return SIMD4(base,
                     accent,
                     Float.random(in: 0.55...1.2, using: &r),
                     Float.random(in: 0...1, using: &r))
    }

    private static func makeScene(_ kind: SceneKind, palette: SIMD4<Float>, rng r: inout SplitMix64) -> SceneSpec {
        let seed = Float.random(in: 1...999, using: &r)
        var subtype: Float = 0
        var flags: Float = 0
        let duration: Float
        switch kind {
        case .cruise:
            subtype = Float.random(in: 0.7...1.4, using: &r)   // speed
            duration = Float.random(in: 20...30, using: &r)
        case .galaxy:
            duration = Float.random(in: 26...38, using: &r)
        case .planet:
            // 0 terran, 1 gas, 2 lava, 3 ice — gas/terran weighted
            let roll = Float.random(in: 0...1, using: &r)
            let type: Float = roll < 0.30 ? 0 : roll < 0.60 ? 1 : roll < 0.80 ? 2 : 3
            subtype = type
            let ringChance: Float = type == 1 ? 0.65 : type == 3 ? 0.3 : 0.12
            flags = Float.random(in: 0...1, using: &r) < ringChance ? 1 : 0
            duration = Float.random(in: 38...48, using: &r)   // full system transit
        case .warp:
            duration = Float.random(in: 7...10, using: &r)
        case .encounter:
            // 0 dyson sphere (flags = stage: 0 ring, 1 partial, 2 full fly-through),
            // 1 black hole, 2 comet swarm, 3 dyson swarm
            subtype = Float(Int.random(in: 0...3, using: &r))
            if subtype == 0 {
                let stage = Int.random(in: 0...2, using: &r)
                flags = Float(stage)
                duration = stage == 2 ? Float.random(in: 52...62, using: &r)   // full journey
                                      : Float.random(in: 28...38, using: &r)
            } else {
                duration = Float.random(in: 26...36, using: &r)
            }
        case .deepfield:
            duration = Float.random(in: 24...32, using: &r)   // subtype/flags set by caller
        }
        return SceneSpec(kind: kind, params: SIMD4(seed, subtype, flags, duration), palette: palette)
    }

    /// A region = arrival warp + 2-3 sightseeing scenes, all sharing a palette.
    private func makeRegion() -> [SceneSpec] {
        let pal = Director.makePalette(&rng)
        let sector = Director.makeSectorName(&rng)
        var warp = Director.makeScene(.warp, palette: pal, rng: &rng)
        warp.sector = sector
        warp.target = "FTL CORRIDOR"
        var scenes: [SceneSpec] = [warp]
        scenes.append(contentsOf: makeRegionTail(palette: pal, sector: sector))
        return scenes
    }

    private func makeRegionTail(palette: SIMD4<Float>, sector: String) -> [SceneSpec] {
        var scenes: [SceneSpec] = []
        let count = Int.random(in: 2...3, using: &rng)
        var lastKind: SceneKind = .warp
        for _ in 0..<count {
            var kind: SceneKind
            let canDeepfield = !imageAspects.isEmpty
            repeat {
                let roll = Float.random(in: 0...1, using: &rng)
                if canDeepfield {
                    kind = roll < 0.21 ? .cruise : roll < 0.47 ? .galaxy : roll < 0.76 ? .planet
                         : roll < 0.89 ? .encounter : .deepfield
                } else {
                    kind = roll < 0.24 ? .cruise : roll < 0.52 ? .galaxy : roll < 0.84 ? .planet : .encounter
                }
            } while kind == lastKind   // avoid identical back-to-back scenes
            lastKind = kind
            var scene = Director.makeScene(kind, palette: palette, rng: &rng)
            scene.sector = sector
            if kind == .deepfield {
                let idx = Int.random(in: 0..<imageAspects.count, using: &rng)
                scene.params.y = Float(idx)                    // image index (host rebinds to screen aspect)
                scene.params.z = imageAspects[idx]             // image aspect for the shader
                scene.target = "ARCHIVE IMG \(Director.designation(&rng))"
            } else {
                scene.target = Director.makeTargetName(kind, subtype: Int(scene.params.y), rng: &rng)
            }
            scenes.append(scene)
        }
        return scenes
    }

    // MARK: telemetry naming

    private static func makeSectorName(_ r: inout SplitMix64) -> String {
        let names = ["KEPLER", "CYGNUS", "VELA", "LYRA", "DRACO", "PERSEUS",
                     "AQUILA", "CARINA", "PHOENIX", "TUCANA", "ERIDANI", "CETUS"]
        let n = names[Int.random(in: 0..<names.count, using: &r)]
        let num = Int.random(in: 11...98, using: &r)
        let suffix = ["A", "B", "C", "D", "E", "F", "G", "K"][Int.random(in: 0...7, using: &r)]
        return "\(n) SECTOR \(num)-\(suffix)"
    }

    private static func designation(_ r: inout SplitMix64) -> String {
        let cats = ["GX", "NGC", "HD", "KOI", "VY", "RX", "TAU", "KEP"]
        return "\(cats[Int.random(in: 0..<cats.count, using: &r)])-\(Int.random(in: 100...9799, using: &r))"
    }

    private static func makeTargetName(_ kind: SceneKind, subtype: Int, rng r: inout SplitMix64) -> String {
        switch kind {
        case .cruise:
            return "DEEP FIELD TRANSIT"
        case .galaxy:
            return "SPIRAL GALAXY \(designation(&r))"
        case .planet:
            let cls = ["CLASS-M SYS", "CLASS-J SYS", "CLASS-Y SYS", "CLASS-P SYS"]
            return "\(designation(&r)) \(cls[min(max(subtype, 0), 3)])"
        case .encounter:
            let what = ["DYSON STRUCTURE", "SINGULARITY", "COMET SWARM", "DYSON SWARM"]
            return "\(what[min(max(subtype, 0), 3)]) \(designation(&r))"
        case .warp:
            return "FTL CORRIDOR"
        case .deepfield:
            return "ARCHIVE OBSERVATION"
        }
    }

    /// Image index the renderer must bind this frame (nil = no deepfield active).
    func activeImageIndex() -> Int? {
        if current.kind == .deepfield { return Int(current.params.y) }
        if previous.kind == .deepfield { return Int(previous.params.y) }
        return nil
    }

    /// Telemetry for the HUD. Call after `uniforms(at:)` for the same time so
    /// the scene timeline has already advanced.
    func hudInfo(at time: Double) -> HUDInfo {
        let t = time - sceneStart
        let dur = Double(max(current.params.w, 1))
        let prog = min(1.0, t / dur)
        let seedPhase = Double(current.params.x) * 0.7

        var speedText: String
        var norm: Double
        switch current.kind {
        case .cruise:
            let v = 0.30 + 0.08 * sin(time * 0.11 + seedPhase)
            speedText = String(format: "%.2f c", v)
            norm = v
        case .galaxy:
            let v = 60 + 2400 * prog * prog
            speedText = String(format: "%.0f c", v)
            norm = 0.45 + 0.35 * prog
        case .planet:
            let v = 0.17 + 0.05 * sin(time * 0.08 + seedPhase)
            speedText = String(format: "%.2f c", v)
            norm = v
        case .encounter:
            let v = 0.16 + 0.05 * sin(time * 0.09 + seedPhase)
            speedText = String(format: "%.2f c", v)
            norm = v + 0.1
        case .warp:
            let v = pow(10.0, 2.0 + 2.6 * prog)
            speedText = String(format: "%.2e c", v)
            norm = 0.55 + 0.45 * prog
        case .deepfield:
            speedText = "0.01 c"        // station-keeping while observing
            norm = 0.04
        }

        let yaw = (Double(current.params.x) * 47.0).truncatingRemainder(dividingBy: 360.0)
            + 9.0 * sin(time * 0.047 + seedPhase)
        let pitch = 11.0 * sin(time * 0.031 + seedPhase * 1.7)

        return HUDInfo(
            sector: current.sector,
            target: current.target,
            kind: current.kind,
            progress: prog,
            remaining: max(0, dur - t),
            warpActive: current.kind == .warp,
            speedText: speedText,
            speedNorm: norm,
            yaw: yaw < 0 ? yaw + 360 : yaw,
            pitch: pitch
        )
    }

    // MARK: timeline

    private func advance(at t: Double) {
        previous = current
        prevSceneStart = sceneStart
        if queue.isEmpty {
            queue = makeRegion()
        }
        current = queue.removeFirst()
        sceneStart = t
        // crossfade length depends on the cut
        if previous.kind == .warp {
            transitionLength = 1.2          // flash-reveal of the new region
        } else if current.kind == .warp {
            transitionLength = 2.2          // accelerate into the jump
        } else {
            transitionLength = 4.5          // slow crossfade; the next body starts as a dot
        }
    }

    func uniforms(at time: Double, resolution: SIMD2<Float>) -> Uniforms {
        // If the machine slept, don't spin through dozens of scenes — resync.
        if time - sceneStart > Double(current.params.w) + 90 {
            sceneStart = time - Double(current.params.w)
        }
        while time - sceneStart >= Double(current.params.w) {
            advance(at: sceneStart + Double(current.params.w))
        }
        let transition = min(1.0, (time - sceneStart) / transitionLength)
        return Uniforms(
            scnA: current.params,
            scnB: previous.params,
            palA: current.palette,
            palB: previous.palette,
            resolution: resolution,
            time: Float(time.truncatingRemainder(dividingBy: 100_000)),
            sceneTime: Float(time - sceneStart),
            prevSceneTime: Float(time - prevSceneStart),
            transition: Float(transition),
            sceneType: current.kind.rawValue,
            prevSceneType: previous.kind.rawValue
        )
    }
}
