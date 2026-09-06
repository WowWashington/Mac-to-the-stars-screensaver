// Standalone temporal checks; no Metal device or screensaver installation needed.
// Build with Sources/Uniforms.swift, Sources/Director.swift and Sources/HUD.swift.
import Foundation
import simd
import Darwin

private var failureCount = 0
private var failureExamples: [String] = []
private var sampleCount = 0
private var sceneCount = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
    if !condition() {
        failureCount += 1
        if failureExamples.count < 12 { failureExamples.append(message()) }
    }
}

private let resolution = SIMD2<Float>(2560, 1440)
private let allKinds: Set<Int32> = [SceneKind.cruise.rawValue, SceneKind.galaxy.rawValue,
    SceneKind.planet.rawValue, SceneKind.warp.rawValue, SceneKind.encounter.rawValue,
    SceneKind.deepfield.rawValue, SceneKind.home.rawValue, SceneKind.rings.rawValue,
    SceneKind.nursery.rawValue]

private struct ImageFixture {
    let name: String
    let aspects: [Float]
    let galaxies: [Int]
}

// Different aspect ratios expose a wrong binding even when both images exist.
private let fixtures = [
    ImageFixture(name: "procedural", aspects: [], galaxies: []),
    ImageFixture(name: "archive", aspects: [1.8, 1.4, 0.75, 2.2, 1.0], galaxies: [0, 3])
]

private func checkedImageIndex(kind: Int32, params: SIMD4<Float>, fixture: ImageFixture,
                               context: String) -> Int? {
    guard let index = Director.imageIndex(kind: kind, params: params) else { return nil }
    check(params.y.rounded() == params.y, "\(context): fractional image selector \(params.y)")
    guard fixture.aspects.indices.contains(index) else {
        check(false, "\(context): image index \(index) is outside the available archive")
        return nil
    }
    check(params.z == fixture.aspects[index], "\(context): image aspect does not match its index")
    return index
}

private func inspect(_ u: Uniforms, hud: HUDInfo, fixture: ImageFixture, context: String) {
    sampleCount += 1
    check(allKinds.contains(u.sceneType) && allKinds.contains(u.prevSceneType),
          "\(context): unknown current or previous scene type")
    for vector in [u.scnA, u.scnB, u.palA, u.palB] {
        check((0..<4).allSatisfy { vector[$0].isFinite }, "\(context): nonfinite uniform vector")
    }
    check(u.scnA.w > 0 && u.scnB.w > 0, "\(context): nonpositive scene duration")
    check(u.resolution == resolution, "\(context): resolution changed")
    check(u.time.isFinite && u.time >= 0 && u.time < 100_000, "\(context): shader clock out of range")
    check(u.transition.isFinite && (0...1).contains(u.transition), "\(context): transition out of range")
    check(u.sceneTime.isFinite && u.sceneTime >= 0 && u.sceneTime < u.scnA.w + 0.001,
          "\(context): current scene clock out of range")
    check(u.prevSceneTime.isFinite && u.prevSceneTime >= u.sceneTime,
          "\(context): previous scene clock moved ahead of current scene")
    check(hud.kind.rawValue == u.sceneType, "\(context): HUD and renderer disagree on scene")
    check(hud.progress.isFinite && (0...1).contains(hud.progress), "\(context): HUD progress out of range")
    check(hud.remaining.isFinite && hud.remaining >= 0, "\(context): invalid remaining time")
    check(hud.speedNorm.isFinite && (0...1).contains(hud.speedNorm), "\(context): invalid HUD speed gauge")
    check(hud.yaw.isFinite && hud.pitch.isFinite, "\(context): nonfinite heading")
    check(hud.warpActive == (u.sceneType == SceneKind.warp.rawValue), "\(context): incorrect warp indicator")
    check(!hud.target.isEmpty && !hud.sector.isEmpty && !hud.speedText.isEmpty,
          "\(context): missing journey telemetry")
    let currentImage = checkedImageIndex(kind: u.sceneType, params: u.scnA,
                                         fixture: fixture, context: context + " current")
    let previousImage = checkedImageIndex(kind: u.prevSceneType, params: u.scnB,
                                          fixture: fixture, context: context + " previous")
    if u.transition < 1, let a = currentImage, let b = previousImage {
        check(a == b, "\(context): crossfade requires two textures (\(b) → \(a)) but renderer binds one")
    }
}

check(MemoryLayout<Uniforms>.size == 96, "CPU/Metal uniform contract requires exactly 96 bytes")
check(MemoryLayout<Uniforms>.stride == 96, "Uniform buffer stride must remain 96 bytes")

for fixture in fixtures {
    var reached = Set<Int32>()
    var encounters = Set<Int>()
    var phaseTargets: [String: Set<String>] = [:]
    // 32 independent openings also exercise the special opening-photo handoff.
    for seed in UInt64(1)...32 {
        let director = Director(seed: seed, imageAspects: fixture.aspects, galaxyImages: fixture.galaxies)
        var start = 0.0
        var lastScene: Uniforms?
        var homeVisitsInRegion = 0
        for sceneNumber in 0..<128 {
            let first = director.uniforms(at: start, resolution: resolution)
            let context = "\(fixture.name) seed=\(seed) scene=\(sceneNumber) type=\(first.sceneType)"
            reached.insert(first.sceneType)
            sceneCount += 1
            if first.sceneType == SceneKind.encounter.rawValue { encounters.insert(Int(first.scnA.y)) }
            if first.sceneType == SceneKind.warp.rawValue { homeVisitsInRegion = 0 }
            if first.sceneType == SceneKind.home.rawValue {
                homeVisitsInRegion += 1
                check(homeVisitsInRegion <= 1, "\(context): home tour repeats within a region")
            }
            if let last = lastScene {
                check(first.prevSceneType == last.sceneType && first.scnB == last.scnA,
                      "\(context): crossfade previous scene does not match the scene just completed")
                // The scripted opening may be followed by another galaxy.
                if sceneNumber > 1 {
                    check(first.sceneType != last.sceneType, "\(context): unexpected consecutive scene kind")
                }
                check(first.sceneTime < 0.001 && first.transition < 0.001,
                      "\(context): new scene did not start from a distant arrival / fresh crossfade")
            }
            var priorTransition: Float = -1
            var targets = Set<String>()
            let duration = Double(first.scnA.w)
            // Include boundary-adjacent frames and enough interior samples to
            // observe every leg without encoding the Director's phase cutoffs.
            for fraction in [0.0, 0.0001, 0.02, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.9999] {
                let time = start + duration * fraction
                let u = director.uniforms(at: time, resolution: resolution)
                let hud = director.hudInfo(at: time)
                inspect(u, hud: hud, fixture: fixture, context: context + " progress=\(fraction)")
                check(u.sceneType == first.sceneType && u.scnA == first.scnA,
                      "\(context): scene changed before its duration elapsed")
                check(u.transition >= priorTransition, "\(context): crossfade moved backward")
                priorTransition = u.transition
                targets.insert(hud.target)
            }
            check(priorTransition == 1, "\(context): scene never completed its crossfade")
            if first.sceneType == SceneKind.rings.rawValue {
                check(targets.count >= 3, "\(context): ring expedition does not describe multiple destinations")
                phaseTargets["rings", default: []].formUnion(targets)
            } else if first.sceneType == SceneKind.nursery.rawValue {
                check(targets.count >= 2, "\(context): nursery telemetry does not progress from arrival to exploration")
                phaseTargets["nursery", default: []].formUnion(targets)
            } else if first.sceneType == SceneKind.encounter.rawValue && Int(first.scnA.y) == 1 {
                check(targets.count >= 4, "\(context): black-hole telemetry omits a stage of the journey")
                phaseTargets["blackhole", default: []].formUnion(targets)
            }
            lastScene = first
            start += duration
        }
        // Resuming after sleep must yield a valid new scene, not an unbounded
        // catch-up loop or scene times large enough to break shader motion.
        let wakeTime = start + 1_000_000
        let afterSleep = director.uniforms(at: wakeTime, resolution: resolution)
        inspect(afterSleep, hud: director.hudInfo(at: wakeTime), fixture: fixture,
                context: "\(fixture.name) seed=\(seed) after sleep")
    }
    let expected = fixture.aspects.isEmpty ? allKinds.subtracting([SceneKind.deepfield.rawValue]) : allKinds
    check(reached == expected, "\(fixture.name): scene coverage differs: reached \(reached.sorted()), expected \(expected.sorted())")
    check(encounters == Set(0...5), "\(fixture.name): an encounter subtype is unreachable")
    let ringLabels = phaseTargets["rings", default: []].joined(separator: " ")
    check(ringLabels.contains("SATURN") && ringLabels.contains("CASSINI") && ringLabels.contains("ENCELADUS"),
          "\(fixture.name): ring expedition lacks meaningful Saturn / ring / moon telemetry")
    let nurseryLabels = phaseTargets["nursery", default: []].joined(separator: " ")
    check(nurseryLabels.contains("DUST") && nurseryLabels.contains("IONIZATION"),
          "\(fixture.name): nursery lacks meaningful dust-pillar telemetry")
    let holeLabels = phaseTargets["blackhole", default: []].joined(separator: " ")
    check(holeLabels.contains("LENSING") && holeLabels.contains("PHOTON") && holeLabels.contains("ESCAPE"),
          "\(fixture.name): black-hole journey lacks survey / close pass / departure telemetry")
}

if failureCount > 0 {
    for message in failureExamples { fputs("FAIL: \(message)\n", stderr) }
    fputs("Director checks failed: \(failureCount) violations across \(sceneCount) scenes / \(sampleCount) frames.\n", stderr)
    exit(1)
}
print("Director checks passed: \(sceneCount) seeded scenes / \(sampleCount) sampled frames, with and without archive images.")
