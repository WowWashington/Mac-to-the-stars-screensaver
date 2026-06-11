// Offscreen preview harness: renders representative frames of every scene
// type to PNGs so the visuals can be inspected without installing the saver.

import Foundation
import Metal
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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
    ("09_planet_ice",      uni(type: .planet, t: 27, seed: 555, subtype: 3, flags: 1, dur: 42, pal: palTeal)),
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
    ("15_comets_mid",      uni(type: .encounter, t: 15, seed: 909, subtype: 2, dur: 30, pal: palTeal)),
]

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
            guard let cb = renderer.encode(into: btex, uniforms: u) else { continue }
            cb.commit()
            cb.waitUntilCompleted()
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
