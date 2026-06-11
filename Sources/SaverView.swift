import ScreenSaver
import Metal
import MetalKit
import QuartzCore

@objc(GalacticOdysseyView)
final class GalacticOdysseyView: ScreenSaverView {
    private let metalLayer = CAMetalLayer()
    private var renderer: SpaceRenderer?
    private var director: Director?
    private var hud: HUDController?
    private var startTime: CFTimeInterval = 0
    private var lastHUDSize: CGSize = .zero
    private var seedImageURLs: [URL] = []
    private var seedAspects: [Float] = []
    private var textureCache: [Int: MTLTexture] = [:]
    private var textureLoader: MTKTextureLoader?

    private var showHUD: Bool {
        // disable with:
        //   defaults -currentHost write com.petersheppard.GalacticOdyssey ShowHUD -bool NO
        let defs = ScreenSaverDefaults(forModuleWithName: "com.petersheppard.GalacticOdyssey")
        guard let defs, defs.object(forKey: "ShowHUD") != nil else { return true }
        return defs.bool(forKey: "ShowHUD")
    }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        return metalLayer
    }

    override var hasConfigureSheet: Bool { false }

    override func startAnimation() {
        super.startAnimation()
        if renderer == nil {
            renderer = SpaceRenderer()
            metalLayer.device = renderer?.device
            if let dev = renderer?.device {
                textureLoader = MTKTextureLoader(device: dev)
            }
            discoverSeedImages()
        }
        if director == nil {
            director = Director(imageAspects: seedAspects)
        }
        // HUD only on full-size screens, never in the Settings thumbnail
        if hud == nil && !isPreview && showHUD && bounds.height > 300 {
            let h = HUDController()
            layer?.addSublayer(h.root)
            hud = h
        }
        if startTime == 0 {
            startTime = CACurrentMediaTime()
        }
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    override func animateOneFrame() {
        guard let renderer, let director else { return }
        updateDrawableSize()
        let t = CACurrentMediaTime() - startTime
        let res = SIMD2<Float>(Float(metalLayer.drawableSize.width),
                               Float(metalLayer.drawableSize.height))
        guard res.x > 0, res.y > 0 else { return }
        var u = director.uniforms(at: t, resolution: res)
        // deepfield scenes: rebind scn.y from image index to SCREEN aspect for
        // the shader, and supply the NASA image texture
        var image: MTLTexture?
        let screenAspect = res.x / res.y
        if u.sceneType == SceneKind.deepfield.rawValue {
            image = texture(at: Int(u.scnA.y))
            u.scnA.y = screenAspect
        }
        if u.prevSceneType == SceneKind.deepfield.rawValue {
            if image == nil, u.transition < 1 { image = texture(at: Int(u.scnB.y)) }
            u.scnB.y = screenAspect
        }
        renderer.draw(to: metalLayer, uniforms: u, image: image)

        if let hud {
            if bounds.size != lastHUDSize {
                lastHUDSize = bounds.size
                hud.layout(in: bounds, scale: window?.backingScaleFactor ?? 2.0)
            }
            hud.update(info: director.hudInfo(at: t), time: t)
        }
    }

    private func discoverSeedImages() {
        let bundle = Bundle(for: GalacticOdysseyView.self)
        var urls = bundle.urls(forResourcesWithExtension: "jpg", subdirectory: "SeedImages") ?? []
        urls.sort { $0.lastPathComponent < $1.lastPathComponent }
        seedImageURLs = []
        seedAspects = []
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        for url in urls {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Double,
                  let h = props[kCGImagePropertyPixelHeight] as? Double, h > 0 else { continue }
            seedImageURLs.append(url)
            seedAspects.append(Float(w / h))
        }
    }

    private func texture(at index: Int) -> MTLTexture? {
        if let t = textureCache[index] { return t }
        guard index >= 0, index < seedImageURLs.count, let loader = textureLoader else { return nil }
        let opts: [MTKTextureLoader.Option: Any] = [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue]
        guard let t = try? loader.newTexture(URL: seedImageURLs[index], options: opts) else { return nil }
        if textureCache.count > 3 { textureCache.removeAll() }   // keep memory modest
        textureCache[index] = t
        return t
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2.0
        var w = bounds.width * scale
        var h = bounds.height * scale
        // cap render resolution (~QHD) — plenty sharp, keeps GPU load modest
        let maxPixels: CGFloat = 3_700_000
        let px = w * h
        if px > maxPixels {
            let f = (maxPixels / px).squareRoot()
            w *= f
            h *= f
        }
        let size = CGSize(width: max(64, w.rounded()), height: max(64, h.rounded()))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }
}
