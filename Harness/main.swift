// Offscreen preview harness: renders representative frames of every scene
// type to PNGs so the visuals can be inspected without installing the saver.

import Foundation
import Metal
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Preserve validation diagnostics even if a later check traps.
setbuf(stdout, nil)

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Preview", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let renderer = SpaceRenderer() else {
    FileHandle.standardError.write("FATAL: renderer init / shader compile failed\n".data(using: .utf8)!)
    exit(1)
}

let W = 1600, H = 900

let desc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
desc.usage = [.renderTarget]
desc.storageMode = .shared
guard let tex = renderer.device.makeTexture(descriptor: desc) else {
    fatalError("texture alloc failed")
}

func writePNG(_ name: String) {
    var bytes = [UInt8](repeating: 0, count: W * H * 4)
    tex.getBytes(&bytes, bytesPerRow: W * 4,
                 from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    let data = Data(bytes)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let provider = CGDataProvider(data: data as CFData),
          let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: W * 4, space: cs, bitmapInfo: info,
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent) else {
        fatalError("CGImage failed")
    }
    let url = outDir.appendingPathComponent("\(name).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("png dest failed")
    }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path)")
}

func uni(type: SceneKind, t: Float, seed: Float, subtype: Float = 0, flags: Float = 0,
         dur: Float = 30, pal: SIMD4<Float>, gt: Float? = nil) -> Uniforms {
    Uniforms(scnA: SIMD4(seed, subtype, flags, dur),
             scnB: SIMD4(seed, subtype, flags, dur),
             palA: pal, palB: pal,
             resolution: SIMD2(Float(W), Float(H)),
             time: gt ?? (t + 40), sceneTime: t, prevSceneTime: t,
             transition: 1.0,
             sceneType: type.rawValue, prevSceneType: type.rawValue)
}

let palBlue  = SIMD4<Float>(0.60, 0.85, 0.9, 0.3)
let palWarm  = SIMD4<Float>(0.05, 0.15, 1.0, 0.7)
let palTeal  = SIMD4<Float>(0.45, 0.10, 0.8, 0.5)

var cases: [(String, Uniforms)] = [
    ("01_cruise_early",    uni(type: .cruise, t: 6,  seed: 137, subtype: 1.0, pal: palBlue)),
    ("02_cruise_herostar", uni(type: .cruise, t: 21, seed: 137, subtype: 1.0, pal: palWarm)),
    ("03_galaxy_far",      uni(type: .galaxy, t: 6,  seed: 412, dur: 32, pal: palBlue)),
    ("04_galaxy_mid",      uni(type: .galaxy, t: 18, seed: 412, dur: 32, pal: palTeal)),
    ("05_galaxy_entry",    uni(type: .galaxy, t: 29, seed: 412, dur: 32, pal: palTeal)),
    ("06_planet_terran",   uni(type: .planet, t: 19, seed: 88,  subtype: 0, dur: 42, pal: palBlue)),
    ("07_planet_gas_ring", uni(type: .planet, t: 20, seed: 251, subtype: 1, flags: 1, dur: 42, pal: palWarm)),
    ("08_planet_lava",     uni(type: .planet, t: 18, seed: 333, subtype: 2, dur: 42, pal: palWarm)),
    ("09_planet_ice",      uni(type: .planet, t: 21, seed: 555, subtype: 3, flags: 1, dur: 42, pal: palTeal)),
    ("18_system_far",      uni(type: .planet, t: 5,  seed: 88,  subtype: 0, dur: 42, pal: palBlue)),
    ("19_system_a",        uni(type: .planet, t: 13, seed: 1234, subtype: 1, dur: 42, pal: palTeal)),
    ("20_system_b",        uni(type: .planet, t: 13, seed: 4242, subtype: 0, dur: 42, pal: palWarm)),
    ("21_system_c",        uni(type: .planet, t: 22, seed: 777, subtype: 2, dur: 42, pal: palBlue)),
    ("10_warp_mid",        uni(type: .warp,   t: 4.5, seed: 77, dur: 9, pal: palTeal)),
    ("11_warp_flash",      uni(type: .warp,   t: 8.4, seed: 77, dur: 9, pal: palBlue)),
    ("13_dyson_mid",       uni(type: .encounter, t: 16, seed: 642, subtype: 0, flags: 1, dur: 30, pal: palWarm)),
    ("23_dyson_ring",      uni(type: .encounter, t: 18, seed: 451, subtype: 0, flags: 0, dur: 32, pal: palWarm)),
    ("24_dyson_partial",   uni(type: .encounter, t: 24, seed: 642, subtype: 0, flags: 1, dur: 34, pal: palBlue)),
    ("25_dyson_interior",  uni(type: .encounter, t: 33, seed: 933, subtype: 0, flags: 2, dur: 56, pal: palBlue)),
    ("26_dyson_entry",     uni(type: .encounter, t: 24.5, seed: 933, subtype: 0, flags: 2, dur: 56, pal: palBlue)),
    ("27_dyson_swarm",     uni(type: .encounter, t: 16, seed: 318, subtype: 3, dur: 32, pal: palTeal)),
    ("14_blackhole_mid",   uni(type: .encounter, t: 17, seed: 271, subtype: 1, dur: 30, pal: palBlue)),
    ("14b_blackhole_close", uni(type: .encounter, t: 27, seed: 271, subtype: 1, dur: 30, pal: palBlue)),
    ("14c_blackhole_far",  uni(type: .encounter, t: 4, seed: 88, subtype: 1, dur: 30, pal: palTeal)),
    ("14d_blackhole_plunge", uni(type: .encounter, t: 29.5, seed: 271, subtype: 1, dur: 30, pal: palBlue)),
    ("15_comets_mid",      uni(type: .encounter, t: 15, seed: 909, subtype: 2, dur: 30, pal: palTeal)),
    // PULSAR (encounter subtype 4) — far flickering dot -> close beam sweep past camera
    ("43_pulsar_far",         uni(type: .encounter, t: 3.5, seed: 512, subtype: 4, dur: 30, pal: palTeal)),
    ("44_pulsar_mid",         uni(type: .encounter, t: 16,  seed: 512, subtype: 4, dur: 30, pal: palBlue)),
    ("45_pulsar_close_sweep", uni(type: .encounter, t: 28,  seed: 512, subtype: 4, dur: 30, pal: palWarm)),
    ("46_pulsar_pulse",       uni(type: .encounter, t: 22,  seed: 271, subtype: 4, dur: 30, pal: palBlue)),
    // ASTEROID BELT (encounter subtype 5) — parallax rock field + hero tumbling rock
    ("47_asteroid_far",       uni(type: .encounter, t: 4,  seed: 618, subtype: 5, dur: 30, pal: palWarm)),
    ("48_asteroid_mid",       uni(type: .encounter, t: 15, seed: 618, subtype: 5, dur: 30, pal: palTeal)),
    ("49_asteroid_hero_close", uni(type: .encounter, t: 15, seed: 903, subtype: 5, dur: 30, pal: palWarm)),
    // HOME SYSTEM tour (scene 6) — seed 300 walks Sun/Venus/Earth+Moon/Mars/Jupiter/Saturn
    ("30_home_sun_approach", uni(type: .home, t: 3.5, seed: 300, dur: 66, pal: palWarm)),
    ("31_home_venus_mid",    uni(type: .home, t: 14.6, seed: 300, dur: 66, pal: palBlue)),
    ("32_home_earth_hero",   uni(type: .home, t: 27.0, seed: 300, dur: 66, pal: palBlue)),
    ("33_home_saturn_rings", uni(type: .home, t: 60.0, seed: 300, dur: 66, pal: palWarm)),
    ("34_home_jupiter",      uni(type: .home, t: 49.4, seed: 300, dur: 66, pal: palWarm)),
    ("35_home_mars",         uni(type: .home, t: 39.4, seed: 300, dur: 66, pal: palWarm)),
    ("36_home_earth_moon2",  uni(type: .home, t: 24.5, seed: 300, dur: 66, pal: palBlue)),
]

// Expansion QA: arrival, survey, close pass and departure are all represented.
for (name, tt) in [("50_rings_arrival", Float(5)), ("51_rings_saturn", Float(24)),
                   ("52_rings_plane", Float(32)), ("52b_rings_plume", Float(40)), ("53_rings_enceladus", Float(48)),
                   ("54_rings_departure", Float(61))] {
    cases.append((name, uni(type: .rings, t: tt, seed: 714, dur: 64, pal: palWarm)))
}
for (name, tt) in [("55_nursery_far", Float(4)), ("56_nursery_pillars", Float(24)),
                   ("57_nursery_close", Float(37))] {
    cases.append((name, uni(type: .nursery, t: tt, seed: 427, dur: 44, pal: palTeal)))
}
for (name, tt) in [("58_horizon_arrival", Float(3)), ("59_horizon_survey", Float(21)),
                   ("60_horizon_inclined", Float(32)), ("61_horizon_close", Float(39.5)),
                   ("62_horizon_departure", Float(47))] {
    cases.append((name, uni(type: .encounter, t: tt, seed: 271, subtype: 1, dur: 48, pal: palBlue)))
}
cases.append(("63_horizon_reverse_spin", uni(type: .encounter, t: 32, seed: 88, subtype: 1, dur: 48, pal: palTeal)))
cases.append(("64_dyson_biosphere", uni(type: .encounter, t: 36, seed: 933, subtype: 0, flags: 2, dur: 56, pal: palBlue)))
cases.append(("65_dyson_architecture", uni(type: .encounter, t: 39, seed: 451, subtype: 0, flags: 2, dur: 56, pal: palWarm)))
cases.append(("66_nursery_variant", uni(type: .nursery, t: 30, seed: 82, dur: 44, pal: palBlue)))
cases.append(("67_rings_variant", uni(type: .rings, t: 48, seed: 188, dur: 64, pal: palWarm)))
for (name, tt) in [("64b_dyson_entry_land", Float(29)), ("64c_dyson_city", Float(33)), ("64d_dyson_sun", Float(41.5))] {
    cases.append((name, uni(type: .encounter, t: tt, seed: 933, subtype: 0, flags: 2, dur: 56, pal: palBlue)))
}
var expeditionFade = uni(type: .nursery, t: 2.25, seed: 427, dur: 44, pal: palTeal)
expeditionFade.prevSceneType = SceneKind.rings.rawValue
expeditionFade.scnB = SIMD4(714, 0, 0, 64)
expeditionFade.prevSceneTime = 66.25
expeditionFade.transition = 0.5
cases.append(("68_transition_rings_nursery", expeditionFade))

// one crossfade case: cruise -> warp mid-transition
var trans = uni(type: .warp, t: 1.0, seed: 77, dur: 9, pal: palTeal)
trans.prevSceneType = SceneKind.cruise.rawValue
trans.scnB = SIMD4(137, 1.0, 0, 25)
trans.palB = palBlue
trans.prevSceneTime = 24
trans.transition = 0.5
cases.append(("12_transition_cruise_to_warp", trans))

// also exercise the Director end-to-end (timeline sanity)
let director = Director(seed: 42)
for probe in [1.0, 30.0, 65.0, 95.0, 130.0] {
    let u = director.uniforms(at: probe, resolution: SIMD2(Float(W), Float(H)))
    print(String(format: "director t=%5.1f -> scene=%d sceneTime=%5.1f transition=%.2f",
                 probe, u.sceneType, u.sceneTime, u.transition))
}

for (name, u) in cases {
    guard let cb = renderer.encode(into: tex, uniforms: u) else { fatalError("encode failed") }
    cb.commit()
    cb.waitUntilCompleted()
    if let err = cb.error { fatalError("GPU error: \(err)") }
    writePNG(name)
}

// HUD composite QA: planet flyby + cockpit overlay, and a warp variant
func writeHUDComposite(_ name: String, base: Uniforms, info: HUDInfo, time: Double) {
    guard let cb = renderer.encode(into: tex, uniforms: base) else { fatalError("encode failed") }
    cb.commit(); cb.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: W * H * 4)
    tex.getBytes(&bytes, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    bytes.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8,
                                  bytesPerRow: W * 4, space: cs, bitmapInfo: info32) else {
            fatalError("ctx failed")
        }
        let hud = HUDController()
        hud.layout(in: CGRect(x: 0, y: 0, width: W, height: H), scale: 2.0)
        hud.update(info: info, time: time)
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)
        hud.root.render(in: ctx)
    }
    let data = Data(bytes)
    guard let provider = CGDataProvider(data: data as CFData),
          let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: W * 4, space: cs,
                            bitmapInfo: CGBitmapInfo(rawValue: info32),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(
              outDir.appendingPathComponent("\(name).png") as CFURL,
              UTType.png.identifier as CFString, 1, nil) else { fatalError("png failed") }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(name).png")
}

writeHUDComposite("16_hud_planet",
    base: uni(type: .planet, t: 15, seed: 88, subtype: 0, dur: 30, pal: palBlue),
    info: HUDInfo(sector: "VELA SECTOR 37-C", target: "TERRAN CLASS-M GX-4471",
                  kind: .planet, progress: 0.5, remaining: 754, warpActive: false,
                  speedText: "0.21 c", speedNorm: 0.21, yaw: 217.4, pitch: 3.2),
    time: 872)
// galaxy approach backed by the real Milky Way archive image
do {
    let mwURL = URL(fileURLWithPath: "SeedImages/PIA10748-milkyway~large.jpg")
    if FileManager.default.fileExists(atPath: mwURL.path) {
        let loader = MTKTextureLoader(device: renderer.device)
        let mwTex = try loader.newTexture(URL: mwURL, options: [.SRGB: false])
        for (name, tt) in [("28_galaxy_photo_far", Float(7)), ("29_galaxy_photo_mid", Float(15))] {
            var u = uni(type: .galaxy, t: tt, seed: 412, dur: 38, pal: palBlue)
            u.scnA.y = 1                  // image index 0 + 1
            u.scnA.z = Float(mwTex.width) / Float(mwTex.height)
            u.scnB = u.scnA
            guard let cb = renderer.encode(into: tex, uniforms: u, image: mwTex) else { fatalError("encode") }
            cb.commit(); cb.waitUntilCompleted()
            writePNG(name)
        }
    } else {
        print("skip galaxy_photo cases (no PIA10748)")
    }
} catch {
    print("galaxy photo case failed: \(error)")
}

// deepfield: NASA seed image with pan/zoom + parallax stars
do {
    let imgURL = URL(fileURLWithPath: "SeedImages/PIA23126~large.jpg")
    if FileManager.default.fileExists(atPath: imgURL.path) {
        let loader = MTKTextureLoader(device: renderer.device)
        let opts: [MTKTextureLoader.Option: Any] = [.SRGB: false]
        let imgTex = try loader.newTexture(URL: imgURL, options: opts)
        var u = uni(type: .deepfield, t: 12, seed: 421, dur: 28, pal: palBlue)
        u.scnA.y = Float(W) / Float(H)                       // screen aspect
        u.scnA.z = Float(imgTex.width) / Float(imgTex.height) // image aspect
        u.scnB = u.scnA
        guard let cb = renderer.encode(into: tex, uniforms: u, image: imgTex) else { fatalError("encode failed") }
        cb.commit(); cb.waitUntilCompleted()
        writePNG("22_deepfield")
    } else {
        print("skip 22_deepfield (no SeedImages/PIA23126~large.jpg)")
    }
} catch {
    print("deepfield case failed: \(error)")
}

// Every new archive asset gets an actual deepfield-render case.
for (name, filename) in [("69_nasa_cosmic_cliffs", "cosmic-cliffs-carina_nebula~large.jpg"),
                          ("70_nasa_helix", "helix-nebula-PIA18164~large.jpg")] {
    let url = URL(fileURLWithPath: "SeedImages/" + filename)
    guard FileManager.default.fileExists(atPath: url.path) else { fatalError("Missing archive asset: \(filename)") }
    let img = try MTKTextureLoader(device: renderer.device).newTexture(URL: url, options: [.SRGB: false])
    var u = uni(type: .deepfield, t: 12, seed: 421, dur: 28, pal: palBlue)
    u.scnA.y = Float(W) / Float(H)
    u.scnA.z = Float(img.width) / Float(img.height)
    u.scnB = u.scnA
    guard let cb = renderer.encode(into: tex, uniforms: u, image: img) else { fatalError("archive encode") }
    cb.commit(); cb.waitUntilCompleted()
    if let error = cb.error { fatalError("archive GPU error: \(error)") }
    writePNG(name)
}

// ---- GPU cost benchmark at QHD (the saver's render cap) ----
if CommandLine.arguments.contains("--bench") {
    let bW = 2560, bH = 1440
    let bdesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: bW, height: bH, mipmapped: false)
    bdesc.usage = [.renderTarget]
    bdesc.storageMode = .private
    let btex = renderer.device.makeTexture(descriptor: bdesc)!
    func bench(_ name: String, _ base: Uniforms) {
        var total = 0.0
        let frames = 40
        for i in 0..<(frames + 5) {
            var u = base
            u.resolution = SIMD2(Float(bW), Float(bH))
            u.time += Float(i) * 0.016
            u.sceneTime += Float(i) * 0.016
            u.prevSceneTime += Float(i) * 0.016
            guard let cb = renderer.encode(into: btex, uniforms: u) else { fatalError("benchmark encode failed") }
            cb.commit()
            cb.waitUntilCompleted()
            if let error = cb.error { fatalError("benchmark GPU error: \(error)") }
            if i >= 5 { total += (cb.gpuEndTime - cb.gpuStartTime) }
        }
        let label = name.padding(toLength: 24, withPad: " ", startingAt: 0)
        print(String(format: "bench \(label) %6.2f ms/frame", total / Double(frames) * 1000.0))
    }
    bench("cruise", uni(type: .cruise, t: 12, seed: 137, subtype: 1.0, pal: palBlue))
    bench("galaxy_mid", uni(type: .galaxy, t: 18, seed: 412, dur: 32, pal: palTeal))
    bench("galaxy_entry", uni(type: .galaxy, t: 27, seed: 412, dur: 32, pal: palTeal))
    bench("system_rings", uni(type: .planet, t: 20, seed: 251, subtype: 1, flags: 1, dur: 42, pal: palWarm))
    bench("warp", uni(type: .warp, t: 4.5, seed: 77, dur: 9, pal: palTeal))
    bench("blackhole", uni(type: .encounter, t: 17, seed: 271, subtype: 1, dur: 30, pal: palBlue))
    bench("dyson_ring", uni(type: .encounter, t: 18, seed: 451, subtype: 0, flags: 0, dur: 32, pal: palWarm))
    bench("dyson_interior", uni(type: .encounter, t: 33, seed: 933, subtype: 0, flags: 2, dur: 56, pal: palBlue))
    bench("dyson_swarm", uni(type: .encounter, t: 16, seed: 318, subtype: 3, dur: 32, pal: palTeal))
    bench("comets", uni(type: .encounter, t: 15, seed: 909, subtype: 2, dur: 30, pal: palTeal))
    bench("pulsar", uni(type: .encounter, t: 16, seed: 512, subtype: 4, dur: 30, pal: palBlue))
    bench("asteroid", uni(type: .encounter, t: 15, seed: 903, subtype: 5, dur: 30, pal: palWarm))
    bench("home_earth", uni(type: .home, t: 27.0, seed: 300, dur: 66, pal: palBlue))
    bench("home_saturn", uni(type: .home, t: 60.0, seed: 300, dur: 66, pal: palWarm))
    bench("horizon_close", uni(type: .encounter, t: 39.5, seed: 271, subtype: 1, dur: 48, pal: palBlue))
    bench("rings_saturn", uni(type: .rings, t: 22, seed: 714, dur: 64, pal: palWarm))
    bench("rings_plane", uni(type: .rings, t: 36, seed: 714, dur: 64, pal: palWarm))
    bench("rings_enceladus", uni(type: .rings, t: 48, seed: 714, dur: 64, pal: palWarm))
    bench("nursery_pillars", uni(type: .nursery, t: 24, seed: 427, dur: 44, pal: palTeal))
    bench("nursery_close", uni(type: .nursery, t: 37, seed: 427, dur: 44, pal: palTeal))
    bench("dyson_architecture", uni(type: .encounter, t: 39, seed: 451, subtype: 0, flags: 2, dur: 56, pal: palWarm))
    bench("expedition_transition", expeditionFade)
    var btrans = uni(type: .warp, t: 1.0, seed: 77, dur: 9, pal: palTeal)
    btrans.prevSceneType = SceneKind.planet.rawValue
    btrans.scnB = SIMD4(251, 1, 1, 42)
    btrans.prevSceneTime = 20
    btrans.transition = 0.5
    bench("transition_worstcase", btrans)
}

writeHUDComposite("17_hud_warp",
    base: uni(type: .warp, t: 4.5, seed: 77, dur: 9, pal: palTeal),
    info: HUDInfo(sector: "PHOENIX SECTOR 81-K", target: "FTL CORRIDOR",
                  kind: .warp, progress: 0.5, remaining: 4, warpActive: true,
                  speedText: "2.51e+04 c", speedNorm: 0.8, yaw: 12.9, pitch: -7.7),
    time: 1204.1)
print("done")

// Verify that specializing scenes and mixing them in HDR preserves presentation.
// Tiny readback targets keep this a quick correctness check, independent of QHD
// timing. This checks outputs rather than duplicating the renderer's blend math.
if CommandLine.arguments.contains("--verify-renderer") {
    let testWidth = 128, testHeight = 72
    let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: testWidth, height: testHeight, mipmapped: false)
    outputDescriptor.storageMode = .shared
    outputDescriptor.usage = [.renderTarget]
    guard let output = renderer.device.makeTexture(descriptor: outputDescriptor) else {
        fatalError("renderer verification: output texture allocation failed")
    }
    // An in-memory color chart makes the image route nontrivial without adding
    // an asset or depending on a particular photograph's brightness.
    let imageDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
    imageDescriptor.storageMode = .shared
    imageDescriptor.usage = [.shaderRead]
    guard let image = renderer.device.makeTexture(descriptor: imageDescriptor) else {
        fatalError("renderer verification: source texture allocation failed")
    }
    var chart = [UInt8](repeating: 255, count: 16 * 16 * 4)
    for y in 0..<16 {
        for x in 0..<16 {
            let offset = (y * 16 + x) * 4
            chart[offset] = UInt8(x * 13 + 20)
            chart[offset + 1] = UInt8(y * 11 + 25)
            chart[offset + 2] = UInt8((x + y) * 7 + 15)
        }
    }
    image.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0,
                  withBytes: &chart, bytesPerRow: 16 * 4)

    func verificationPixels(_ base: Uniforms) -> [UInt8] {
        var u = base
        u.resolution = SIMD2(Float(testWidth), Float(testHeight))
        guard let command = renderer.encode(into: output, uniforms: u, image: image) else {
            fatalError("renderer verification: encode failed")
        }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed && command.error == nil else {
            fatalError("renderer verification: GPU error \(String(describing: command.error))")
        }
        var bytes = [UInt8](repeating: 0, count: testWidth * testHeight * 4)
        output.getBytes(&bytes, bytesPerRow: testWidth * 4,
                        from: MTLRegionMake2D(0, 0, testWidth, testHeight), mipmapLevel: 0)
        return bytes
    }

    var verificationFailures: [String] = []
    func comparePresentation(_ name: String, _ lhs: [UInt8], _ rhs: [UInt8],
                             maxAllowed: Int? = nil, meanAllowed: Double = 0.2) {
        guard lhs.count == rhs.count else { fatalError("renderer verification: readback sizes differ") }
        var maximum = 0
        var total = 0
        var channels = 0
        var largeDifferences = 0
        var affectedPixels = Set<Int>()
        for index in lhs.indices {
            let difference = abs(Int(lhs[index]) - Int(rhs[index]))
            maximum = max(maximum, difference)
            if index % 4 != 3 {
                total += difference
                channels += 1
                if difference > 4 {
                    largeDifferences += 1
                    affectedPixels.insert(index / 4)
                }
            }
        }
        let mean = Double(total) / Double(channels)
        let largeFraction = Double(largeDifferences) / Double(channels)
        let pixelFraction = Double(affectedPixels.count) / Double(lhs.count / 4)
        // The two specialized programs may reassociate floating-point work.
        // Tiny changes can move a procedural hash, star edge or ray-march
        // sample across a boundary, so maximum error alone is misleading.
        // Bound total error to <0.08% of display range, and require 99.8% of
        // RGB channels to differ by no more than 4/255. Endpoint selection
        // uses the same program and retains its separate strict maximum.
        let passes = mean <= meanAllowed && largeFraction <= 0.002
                  && (maxAllowed.map { maximum <= $0 } ?? true)
        let summary = String(format: "%@ max=%d mean=%.4f >4=%d/%.4f%% channels (%.4f%% pixels)",
                             name, maximum, mean, largeDifferences, largeFraction * 100, pixelFraction * 100)
        print("verify renderer \(passes ? "PASS" : "FAIL") \(summary)")
        if !passes {
            verificationFailures.append(summary)
        }
    }

    var routes: [(String, Uniforms)] = [
        ("cruise", uni(type: .cruise, t: 12, seed: 137, subtype: 1, pal: palBlue)),
        ("galaxy", uni(type: .galaxy, t: 20, seed: 412, dur: 32, pal: palTeal)),
        ("system", uni(type: .planet, t: 20, seed: 251, subtype: 1, flags: 1, dur: 42, pal: palWarm)),
        ("warp", uni(type: .warp, t: 4.5, seed: 77, dur: 9, pal: palTeal)),
        ("archive", uni(type: .deepfield, t: 12, seed: 421, dur: 28, pal: palBlue)),
        ("home", uni(type: .home, t: 27, seed: 300, dur: 66, pal: palBlue)),
        ("rings", uni(type: .rings, t: 36, seed: 714, dur: 64, pal: palWarm)),
        ("nursery", uni(type: .nursery, t: 24, seed: 427, dur: 44, pal: palTeal))
    ]
    for subtype in 0...5 {
        routes.append(("encounter \(subtype)",
                       uni(type: .encounter, t: 23, seed: 271, subtype: Float(subtype),
                           dur: 40, pal: palBlue)))
    }
    routes.append(("dyson interior", uni(type: .encounter, t: 39, seed: 451,
                                         subtype: 0, flags: 2, dur: 56, pal: palWarm)))
    for (name, base) in routes {
        var direct = base
        if direct.sceneType == SceneKind.deepfield.rawValue {
            direct.scnA.y = Float(testWidth) / Float(testHeight)
            direct.scnA.z = 1
        }
        direct.scnB = direct.scnA
        direct.palB = direct.palA
        direct.prevSceneType = direct.sceneType
        direct.prevSceneTime = direct.sceneTime
        direct.transition = 1
        var selfFade = direct
        selfFade.transition = 0.37
        comparePresentation(name, verificationPixels(direct), verificationPixels(selfFade))
    }

    let previous = uni(type: .rings, t: 36, seed: 714, dur: 64, pal: palWarm, gt: 73)
    let current = uni(type: .nursery, t: 24, seed: 427, dur: 44, pal: palTeal, gt: 73)
    var transition = current
    transition.prevSceneType = previous.sceneType
    transition.scnB = previous.scnA
    transition.palB = previous.palA
    transition.prevSceneTime = previous.sceneTime
    transition.transition = 0
    comparePresentation("previous endpoint", verificationPixels(previous), verificationPixels(transition),
                         maxAllowed: 1, meanAllowed: 0.05)
    transition.transition = 1
    comparePresentation("current endpoint", verificationPixels(current), verificationPixels(transition),
                         maxAllowed: 1, meanAllowed: 0.05)
    if !verificationFailures.isEmpty {
        let report = "Renderer verification failed after checking all routes:\n"
                   + verificationFailures.joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(report.utf8))
        exit(1)
    }
    print("renderer verification passed: 15 specialized routes and both crossfade endpoints")
}
