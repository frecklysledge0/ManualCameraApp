import Metal
import QuartzCore

/// Swift mirror of `PreviewParams` in Shaders.metal.
private struct PreviewParams {
    var quarterTurns: UInt32
    var mirrored: UInt32
    var sourceIsP3: UInt32
    var padding: UInt32 = 0
}

/// The Edition's live viewfinder (Slice 3 §7): draws each video frame through the same LUT as the
/// developed still into an opaque Metal layer above the preview layer. It plugs into
/// `FramePipeline.frameRenderer`, so it runs on the video queue inside the frame's command buffer.
final class EditionPreviewRenderer: @unchecked Sendable {

    private let lock = NSLock()
    private weak var layer: CAMetalLayer?
    private var grainAmplitude: Float = 0
    private var sourceIsP3 = true

    init(layer: CAMetalLayer) {
        self.layer = layer
        layer.isOpaque = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
    }

    /// Optional cheap static grain at half strength (Slice 3 §7).
    func setGrain(_ level: GrainLevel, iso: Float) {
        lock.lock()
        grainAmplitude = GrainMath.amplitude(for: level, iso: iso) * LookConstants.previewGrainScale
        lock.unlock()
    }

    func setSourceIsP3(_ isP3: Bool) {
        lock.lock()
        sourceIsP3 = isP3
        lock.unlock()
    }

    /// Encodes one frame. Called by `FramePipeline` on the video queue.
    func render(commandBuffer: MTLCommandBuffer, luma: MTLTexture, chroma: MTLTexture, quarterTurns: Int, mirrored: Bool) {
        let resources = LookResources.shared
        guard let pipeline = resources.previewPipeline, let lut = resources.lut, let noise = resources.noise else { return }
        lock.lock()
        let target = layer
        let amplitude = grainAmplitude
        let isP3 = sourceIsP3
        lock.unlock()
        guard let target, target.drawableSize.width > 0, target.drawableSize.height > 0,
              let drawable = target.nextDrawable(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let output = drawable.texture
        // Static grain: scale from the drawable height, fixed seed so it doesn't shimmer.
        var look = LookParams.make(
            grainAmplitude: amplitude,
            grainScale: max(0.5, LookConstants.grainFineSize * Float(output.height) / LookConstants.grainReferenceHeight * 2),
            seed: 1
        )
        var params = PreviewParams(
            quarterTurns: UInt32(((quarterTurns % 4) + 4) % 4),
            mirrored: mirrored ? 1 : 0,
            sourceIsP3: isP3 ? 1 : 0
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setTexture(lut, index: 3)
        encoder.setTexture(noise, index: 4)
        encoder.setBytes(&look, length: MemoryLayout<LookParams>.stride, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<PreviewParams>.stride, index: 1)
        LookResources.dispatch(encoder, pipeline: pipeline, width: output.width, height: output.height)
        encoder.endEncoding()
        commandBuffer.present(drawable)
    }
}
