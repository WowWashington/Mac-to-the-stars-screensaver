// Renders a short highlight reel of the saver to an animated GIF for the README.
// Build/run via ./build.sh gif — compiles with the same shared sources as the harness.

import Foundation
import Metal
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let W = 440, H = 248
let FPS: Float = 8
let outURL = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "demo.gif")

guard let renderer = SpaceRenderer() else {
    FileHandle.standardError.write("renderer init failed\n".data(using: .utf8)!)
    exit(1)
}

let desc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
desc.usage = [.renderTarget]
desc.storageMode = .shared
let tex = renderer.device.makeTexture(descriptor: desc)!

func uni(type: SceneKind, t: Float, seed: Float, subtype: Float = 0, flags: Float = 0,
         dur: Float = 30, pal: SIMD4<Float>) -> Uniforms {
    Uniforms(scnA: SIMD4(seed, subtype, flags, dur),
             scnB: SIMD4(seed, subtype, flags, dur),
             palA: pal, palB: pal,
             resolution: SIMD2(Float(W), Float(H)),
             time: t + 40, sceneTime: t, prevSceneTime: t,
             transition: 1.0,
             sceneType: type.rawValue, prevSceneType: type.rawValue)
}

let palBlue = SIMD4<Float>(0.60, 0.85, 0.9, 0.3)
let palWarm = SIMD4<Float>(0.05, 0.15, 1.0, 0.7)
let palTeal = SIMD4<Float>(0.45, 0.10, 0.8, 0.5)

struct Clip {
    var base: Uniforms
    var t0: Float
    var t1: Float
    var image: MTLTexture? = nil
}

var clips: [Clip] = []

// 1. opening: Milky Way photo approach
if FileManager.default.fileExists(atPath: "SeedImages/PIA10748-milkyway~large.jpg") {
    let loader = MTKTextureLoader(device: renderer.device)
    if let mw = try? loader.newTexture(
        URL: URL(fileURLWithPath: "SeedImages/PIA10748-milkyway~large.jpg"),
        options: [.SRGB: false]) {
        var u = uni(type: .galaxy, t: 0, seed: 412, dur: 38, pal: palBlue)
        u.scnA.y = 1
        u.scnA.z = Float(mw.width) / Float(mw.height)
        u.scnB = u.scnA
        clips.append(Clip(base: u, t0: 4, t1: 11, image: mw))
    }
}
// 2. home system: Earth + Moon hero pass
clips.append(Clip(base: uni(type: .home, t: 0, seed: 300, dur: 66, pal: palBlue),
                  t0: 23, t1: 29))
// 3. black hole: orbit with jet, then the plunge
clips.append(Clip(base: uni(type: .encounter, t: 0, seed: 271, subtype: 1, dur: 30, pal: palBlue),
                  t0: 18, t1: 29.5))
// 4. warp out
clips.append(Clip(base: uni(type: .warp, t: 0, seed: 77, dur: 9, pal: palTeal),
                  t0: 2, t1: 7))

let totalFrames = clips.reduce(0) { $0 + Int(($1.t1 - $1.t0) * FPS) }
print("rendering \(totalFrames) frames at \(W)x\(H) @\(Int(FPS))fps")

guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL,
        UTType.gif.identifier as CFString, totalFrames, nil) else {
    fatalError("gif destination failed")
}
let gifProps = [kCGImagePropertyGIFDictionary as String:
                [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary
CGImageDestinationSetProperties(dest, gifProps)
let frameProps = [kCGImagePropertyGIFDictionary as String:
                  [kCGImagePropertyGIFDelayTime as String: 1.0 / Double(FPS)]] as CFDictionary

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
    | CGBitmapInfo.byteOrder32Little.rawValue)

for clip in clips {
    let n = Int((clip.t1 - clip.t0) * FPS)
    for f in 0..<n {
        let t = clip.t0 + Float(f) / FPS
        var u = clip.base
        u.sceneTime = t
        u.prevSceneTime = t
        u.time = t + 40
        guard let cb = renderer.encode(into: tex, uniforms: u, image: clip.image) else {
            fatalError("encode failed")
        }
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        tex.getBytes(&bytes, bytesPerRow: W * 4,
                     from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: W * 4, space: cs, bitmapInfo: info,
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent) else { fatalError("cgimage failed") }
        CGImageDestinationAddImage(dest, img, frameProps)
    }
}
guard CGImageDestinationFinalize(dest) else { fatalError("gif finalize failed") }
let sz = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
print("wrote \(outURL.path) (\(sz / 1024) KB)")
