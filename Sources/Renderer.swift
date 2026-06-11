import Metal
import QuartzCore

final class SpaceRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private(set) var dummyTexture: MTLTexture!

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        do {
            let lib = try dev.makeLibrary(source: spaceShaderSource, options: nil)
            guard let vfn = lib.makeFunction(name: "vmain"),
                  let ffn = lib.makeFunction(name: "fmain") else { return nil }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try dev.makeRenderPipelineState(descriptor: desc)
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

    func encode(into texture: MTLTexture, uniforms: Uniforms, image: MTLTexture? = nil) -> MTLCommandBuffer? {
        var u = uniforms
        guard let cb = queue.makeCommandBuffer() else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = texture
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(image ?? dummyTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
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
