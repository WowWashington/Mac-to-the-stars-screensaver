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

    private var configPanel: NSPanel?
    private weak var hudCheckbox: NSButton?

    private static let prefsModule = "com.petersheppard.GalacticOdyssey"

    private var showHUD: Bool {
        // toggled via the Options… sheet in System Settings (or:
        //   defaults -currentHost write com.petersheppard.GalacticOdyssey ShowHUD -bool NO)
        let defs = ScreenSaverDefaults(forModuleWithName: Self.prefsModule)
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

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        if let panel = configPanel {
            hudCheckbox?.state = showHUD ? .on : .off
            return panel
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 170),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Galactic Odyssey"
        guard let content = panel.contentView else { return panel }

        let title = NSTextField(labelWithString: "Galactic Odyssey Options")
        title.font = .boldSystemFont(ofSize: 13)
        title.frame = NSRect(x: 24, y: 132, width: 352, height: 20)
        content.addSubview(title)

        let check = NSButton(checkboxWithTitle: "Show starship HUD (telemetry overlay)",
                             target: nil, action: nil)
        check.state = showHUD ? .on : .off
        check.frame = NSRect(x: 24, y: 100, width: 352, height: 20)
        content.addSubview(check)
        hudCheckbox = check

        let credit = NSTextField(labelWithString: "Deep-field imagery courtesy NASA (images.nasa.gov)")
        credit.font = .systemFont(ofSize: 11)
        credit.textColor = .secondaryLabelColor
        credit.frame = NSRect(x: 24, y: 72, width: 352, height: 16)
        content.addSubview(credit)

        let ok = NSButton(title: "OK", target: self, action: #selector(configOK(_:)))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.frame = NSRect(x: 304, y: 16, width: 72, height: 30)
        content.addSubview(ok)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(configCancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 224, y: 16, width: 76, height: 30)
        content.addSubview(cancel)

        configPanel = panel
        return panel
    }

    @objc private func configOK(_ sender: Any?) {
        if let defs = ScreenSaverDefaults(forModuleWithName: Self.prefsModule) {
            defs.set(hudCheckbox?.state == .on, forKey: "ShowHUD")
            defs.synchronize()
        }
        applyHUDVisibility()
        dismissConfigSheet()
    }

    @objc private func configCancel(_ sender: Any?) {
        dismissConfigSheet()
    }

    private func dismissConfigSheet() {
        guard let panel = configPanel else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
    }

    private func applyHUDVisibility() {
        if !showHUD {
            hud?.root.removeFromSuperlayer()
            hud = nil
        } else if hud == nil, !isPreview, bounds.height > 300 {
            let h = HUDController()
            layer?.addSublayer(h.root)
            hud = h
            lastHUDSize = .zero        // force re-layout on next frame
        }
    }

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
            let galaxyIdx = seedImageURLs.indices.filter {
                let n = seedImageURLs[$0].lastPathComponent.lowercased()
                return n.contains("milky") || n.contains("galaxy")
            }
            director = Director(imageAspects: seedAspects, galaxyImages: galaxyIdx)
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
        // bind the NASA image texture for whichever active scene needs one
        // (deepfield or photo-backed galaxy); deepfield also swaps scn.y from
        // image index to SCREEN aspect for the shader
        var image: MTLTexture?
        let screenAspect = res.x / res.y
        if let idx = Director.imageIndex(kind: u.sceneType, params: u.scnA) {
            image = texture(at: idx)
        }
        if u.transition < 1, image == nil,
           let idx = Director.imageIndex(kind: u.prevSceneType, params: u.scnB) {
            image = texture(at: idx)
        }
        if u.sceneType == SceneKind.deepfield.rawValue { u.scnA.y = screenAspect }
        if u.prevSceneType == SceneKind.deepfield.rawValue { u.scnB.y = screenAspect }
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
