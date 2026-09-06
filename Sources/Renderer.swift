import Metal
import QuartzCore

final class SpaceRenderer {
    private struct SceneKey: Hashable {
        let kind: Int32
        let subtype: Int32
    }
    private struct ScenePipelines {
        let direct: MTLRenderPipelineState
        let linear: MTLRenderPipelineState
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [SceneKey: ScenePipelines]
    private let compositePipeline: MTLRenderPipelineState
    private var transitionTexture: MTLTexture?
    private(set) var dummyTexture: MTLTexture!

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        do {
            let lib = try dev.makeLibrary(source: spaceShaderSource, options: nil)
            guard let vfn = lib.makeFunction(name: "vmain"),
                  let composite = lib.makeFunction(name: "fcomposite") else { return nil }
            var compiled: [SceneKey: ScenePipelines] = [:]
            // Compile every route before animation starts. Function constants
            // let Metal discard unrelated scenes, including encounter subtypes,
            // rather than reserve registers for the entire procedural universe.
            let kinds = SceneKind.allCases
            for kind in kinds {
                let subtypes = kind == .encounter ? Array(Int32(0)...5) : [Int32(0)]
                for subtype in subtypes {
                    let key = SceneKey(kind: kind.rawValue, subtype: subtype)
                    func makePipeline(linear: Bool) throws -> MTLRenderPipelineState {
                        let constants = MTLFunctionConstantValues()
                        var kindValue = kind.rawValue
                        var subtypeValue = subtype
                        var linearValue = linear
                        constants.setConstantValue(&kindValue, type: .int, index: 0)
                        constants.setConstantValue(&subtypeValue, type: .int, index: 1)
                        constants.setConstantValue(&linearValue, type: .bool, index: 2)
                        let fragment = try lib.makeFunction(name: "fscene", constantValues: constants)
                        let descriptor = MTLRenderPipelineDescriptor()
                        descriptor.label = "scene \(kind.rawValue)/\(subtype) \(linear ? "linear" : "display")"
                        descriptor.vertexFunction = vfn
                        descriptor.fragmentFunction = fragment
                        let attachment = descriptor.colorAttachments[0]!
                        attachment.pixelFormat = linear ? .rgba16Float : .bgra8Unorm
                        if linear {
                            // Both scenes accumulate their weighted radiance in
                            // one HDR target. Tonemapping happens after the mix.
                            attachment.isBlendingEnabled = true
                            attachment.rgbBlendOperation = .add
                            attachment.sourceRGBBlendFactor = .sourceAlpha
                            attachment.destinationRGBBlendFactor = .one
                            attachment.alphaBlendOperation = .add
                            attachment.sourceAlphaBlendFactor = .zero
                            attachment.destinationAlphaBlendFactor = .one
                        }
                        return try dev.makeRenderPipelineState(descriptor: descriptor)
                    }
                    compiled[key] = try ScenePipelines(direct: makePipeline(linear: false),
                                                       linear: makePipeline(linear: true))
                }
            }
            pipelines = compiled
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "linear crossfade presentation"
            desc.vertexFunction = vfn
            desc.fragmentFunction = composite
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            compositePipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("GalacticOdyssey: shader compile failed: \(error)")
            return nil
        }
        let dd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        dd.usage = [.shaderRead]
        dummyTexture = dev.makeTexture(descriptor: dd)
        var black: UInt32 = 0xFF000000
        dummyTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                             mipmapLevel: 0, withBytes: &black, bytesPerRow: 4)
    }

    private func pipeline(for u: Uniforms) -> ScenePipelines? {
        let subtype = u.sceneType == SceneKind.encounter.rawValue ? Int32(u.scnA.y.rounded()) : 0
        return pipelines[SceneKey(kind: u.sceneType, subtype: subtype)]
    }

    private func linearTarget(width: Int, height: Int) -> MTLTexture? {
        if let existing = transitionTexture, existing.width == width, existing.height == height {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        transitionTexture = device.makeTexture(descriptor: descriptor)
        transitionTexture?.label = "linear scene crossfade"
        return transitionTexture
    }

    private func drawScene(_ uniforms: Uniforms, encoder: MTLRenderCommandEncoder,
                           image: MTLTexture, linear: Bool) -> Bool {
        var u = uniforms
        guard let scene = pipeline(for: u) else {
            NSLog("GalacticOdyssey: no pipeline for scene %d subtype %.0f", u.sceneType, u.scnA.y)
            return false
        }
        encoder.setRenderPipelineState(linear ? scene.linear : scene.direct)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(image, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        return true
    }

    func encode(into texture: MTLTexture, uniforms: Uniforms, image: MTLTexture? = nil) -> MTLCommandBuffer? {
        guard let cb = queue.makeCommandBuffer() else { return nil }
        cb.label = "Galactic Odyssey frame"
        cb.addCompletedHandler { completed in
            if completed.status == .error {
                NSLog("GalacticOdyssey: GPU frame failed: %@", String(describing: completed.error))
            }
        }
        let imageTexture = image ?? dummyTexture!
        var current = uniforms
        var previous = uniforms
        previous.scnA = uniforms.scnB
        previous.palA = uniforms.palB
        previous.sceneTime = uniforms.prevSceneTime
        previous.sceneType = uniforms.prevSceneType

        let fading = uniforms.transition > 0 && uniforms.transition < 1
        if fading {
            guard let linearTexture = linearTarget(width: texture.width, height: texture.height) else {
                NSLog("GalacticOdyssey: could not allocate the linear crossfade texture")
                return nil
            }
            let blend = uniforms.transition * uniforms.transition * (3 - 2 * uniforms.transition)
            previous.transition = 1 - blend
            current.transition = blend
            let blendPass = MTLRenderPassDescriptor()
            blendPass.colorAttachments[0].texture = linearTexture
            blendPass.colorAttachments[0].loadAction = .clear
            blendPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            blendPass.colorAttachments[0].storeAction = .store
            guard let blendEncoder = cb.makeRenderCommandEncoder(descriptor: blendPass) else { return nil }
            blendEncoder.label = "blend specialized scenes in linear light"
            let previousOK = drawScene(previous, encoder: blendEncoder, image: imageTexture, linear: true)
            let currentOK = drawScene(current, encoder: blendEncoder, image: imageTexture, linear: true)
            blendEncoder.endEncoding()
            guard previousOK && currentOK else { return nil }
        }

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = texture
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        if fading {
            enc.setRenderPipelineState(compositePipeline)
            var u = uniforms
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(transitionTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        } else {
            let active = uniforms.transition <= 0 ? previous : current
            guard drawScene(active, encoder: enc, image: imageTexture, linear: false) else {
                enc.endEncoding()
                return nil
            }
        }
        enc.endEncoding()
        return cb
    }

    func draw(to layer: CAMetalLayer, uniforms: Uniforms, image: MTLTexture? = nil) {
        guard let drawable = layer.nextDrawable(),
              let cb = encode(into: drawable.texture, uniforms: uniforms, image: image) else { return }
        cb.present(drawable)
        cb.commit()
    }
}
