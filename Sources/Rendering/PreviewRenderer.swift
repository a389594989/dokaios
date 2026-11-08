import MetalKit
import SwiftUI

struct FilmParams {
    var intensity: Float = 1
    var grain: Float = 0.05
    var vignette: Float = 0.2
    var time: Float = 0
    var lutEnabled: Float = 0
}

/// 把相机帧经 3D LUT + 颗粒 + 暗角 实时渲染到 MTKView。
final class PreviewRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let dummyLUT: MTLTexture

    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    /// 以下属性仅在主线程修改/读取 (MTKView 默认在主线程绘制)。
    var params = FilmParams()
    private var lutTexture: MTLTexture?

    init?(useDefaultDevice: Bool = true) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "previewVertex")
        desc.fragmentFunction = library.makeFunction(name: "previewFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }

        let d3 = MTLTextureDescriptor()
        d3.textureType = .type3D
        d3.pixelFormat = .rgba8Unorm
        d3.width = 2; d3.height = 2; d3.depth = 2
        d3.usage = .shaderRead
        guard let dummy = device.makeTexture(descriptor: d3) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.dummyLUT = dummy
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// 任意线程调用。
    func submit(_ pixelBuffer: CVPixelBuffer) {
        lock.lock(); latest = pixelBuffer; lock.unlock()
    }

    func setLUT(_ texture: MTLTexture?) {
        lutTexture = texture
        params.lutEnabled = texture == nil ? 0 : 1
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock(); let pb = latest; lock.unlock()
        guard let pb, let cache = textureCache,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }

        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm,
                                                        w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let frame = CVMetalTextureGetTexture(cvTex),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        // aspect-fill: 取景器按屏幕比例居中裁切相机帧
        let ds = view.drawableSize
        let imgA = Float(w) / Float(h), viewA = Float(ds.width / max(ds.height, 1))
        var scale = viewA > imgA ? SIMD2<Float>(1, imgA / viewA) : SIMD2<Float>(viewA / imgA, 1)

        var p = params
        p.time = Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 1000))

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        enc.setFragmentTexture(frame, index: 0)
        enc.setFragmentTexture(lutTexture ?? dummyLUT, index: 1)
        enc.setFragmentBytes(&p, length: MemoryLayout<FilmParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        cmd.present(drawable)
        cmd.addCompletedHandler { _ in withExtendedLifetime(cvTex) {} }
        cmd.commit()
    }
}

struct MetalPreviewView: UIViewRepresentable {
    let renderer: PreviewRenderer?

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = renderer
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
