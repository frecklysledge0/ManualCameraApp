import AVFoundation
import CoreImage
import Metal
import QuartzCore
import simd

/// RGB + luma histogram, each normalised so its tallest bin is 1.
struct HistogramSample: Equatable, Sendable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    var luma: [Float]
    /// Fraction of samples in the lowest and highest luma bins (clip markers).
    var shadowClip: Float
    var highlightClip: Float

    static let empty = HistogramSample(red: [], green: [], blue: [], luma: [], shadowClip: 0, highlightClip: 0)

    /// Clip markers light up above 0.5% of samples (Slice 2 §9).
    static let clipMarkerFraction: Float = 0.005

    var isEmpty: Bool { red.isEmpty }
    var clipsHighlights: Bool { highlightClip > Self.clipMarkerFraction }
    var clipsShadows: Bool { shadowClip > Self.clipMarkerFraction }

    /// Largest absolute bin difference against another sample (used to skip identical publishes).
    func maxDifference(to other: HistogramSample) -> Float {
        guard red.count == other.red.count, !red.isEmpty else { return .infinity }
        var largest: Float = 0
        for index in red.indices {
            largest = max(largest, abs(red[index] - other.red[index]))
            largest = max(largest, abs(green[index] - other.green[index]))
            largest = max(largest, abs(blue[index] - other.blue[index]))
            largest = max(largest, abs(luma[index] - other.luma[index]))
        }
        return largest
    }
}

enum ThermalLevel: Int, Comparable, Sendable {
    case nominal, fair, serious, critical

    static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Swift mirrors of the Metal parameter structs (Shaders.metal)

private struct OverlayParams {
    var quarterTurns: UInt32
    var mirrored: UInt32
    var threshold: Float
    var stepScale: Float
    var color: SIMD4<Float>
    var lumaTexel: SIMD2<Float>
    var peakingEnabled: UInt32
    var zebrasEnabled: UInt32
    var zebraThreshold: Float
    var time: Float
    var flash: Float
    var padding: Float = 0
}

private struct HistogramParams {
    var width: UInt32
    var height: UInt32
}

private struct SharpnessParams {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var gridWidth: UInt32
    var gridHeight: UInt32
    var lumaTexel: SIMD2<Float>
}

private struct LoupeParams {
    var center: SIMD2<Float>
    var windowSize: SIMD2<Float>
    var quarterTurns: UInt32
    var mirrored: UInt32
    var nearest: UInt32
    var threshold: Float
    var peakColor: SIMD4<Float>
    var lumaTexel: SIMD2<Float>
    var peaking: UInt32
    var padding: Float = 0
}

/// The `AVCaptureVideoDataOutput` delegate (Slice 1 §6.2, Slice 2 §8–9). Everything runs on
/// `videoQueue` and the GPU: no `UIImage`, no per-frame allocation, no main-thread hop for drawing.
/// Peaking and zebras share one overlay pass; the loupe and the sharpness metric read the
/// native-resolution frame.
final class FramePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    struct Config: Equatable {
        var peakingEnabled = false
        var peakingColor = SIMD4<Float>(1.0, 0.333, 0.0, 0.95)
        var peakingThreshold: Float = 0.22
        var zebrasEnabled = false
        var zebraThreshold: Float = 0.95
        var histogramEnabled = true
        /// Edge-energy metric for the focus snap; computed only while pulling focus.
        var sharpnessEnabled = false
        /// ROI in display uv (0…1), centred on the focus point.
        var sharpnessROI = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        var loupeEnabled = false
        /// Loupe centre in display uv.
        var loupeCenter = CGPoint(x: 0.5, y: 0.5)
        /// Display-uv size of the region shown in the loupe.
        var loupeWindow = CGSize(width: 0.1, height: 0.1)
        var loupeNearest = false
        var quarterTurns = 1
        var mirrored = false
        var thermal: ThermalLevel = .nominal
        var feedFrameRate: Double = 30
    }

    let videoQueue = DispatchQueue(label: "camera.videoQueue", qos: .userInteractive)
    let metalDevice: MTLDevice?

    /// Called on a background thread with a new histogram (≤30 Hz).
    var onHistogram: ((HistogramSample) -> Void)?
    /// Called on `videoQueue` with the first frame from the device passed to `expectFirstFrame`.
    var onFirstFrame: (() -> Void)?
    /// Called once a second with the measured feed frame rate (debug HUD).
    var onFeedRate: ((Double) -> Void)?
    /// Called on a background thread with the focus-ROI edge energy, once per frame while enabled.
    var onSharpness: ((Double) -> Void)?
    /// Called on `videoQueue` when the native buffer size changes (decides whether 8× loupe is real).
    var onBufferSize: ((CGSize) -> Void)?

    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var overlayPipeline: MTLComputePipelineState?
    private var histogramPipeline: MTLComputePipelineState?
    private var sharpnessPipeline: MTLComputePipelineState?
    private var loupePipeline: MTLComputePipelineState?
    private var histogramBuffers: [MTLBuffer] = []
    private var histogramBufferIndex = 0
    private let histogramSlots = DispatchSemaphore(value: 2)
    private let histogramGrid = (width: 256, height: 192)
    private var sharpnessBuffers: [MTLBuffer] = []
    private var sharpnessBufferIndex = 0
    private let sharpnessSlots = DispatchSemaphore(value: 2)
    private let sharpnessGrid = 128

    private let stateLock = NSLock()
    private var config = Config()
    private weak var overlayLayer: CAMetalLayer?
    private weak var loupeLayer: CAMetalLayer?
    private var expectedDeviceID: String?
    private var flashUntil: TimeInterval = 0

    // videoQueue-confined state
    private var frameIndex: UInt64 = 0
    private var overlayHasContent = false
    private var latestPixelBuffer: CVPixelBuffer?
    private var lastHistogramTime: TimeInterval = 0
    private var rateWindowStart: TimeInterval = 0
    private var rateWindowFrames = 0
    private var lastBufferSize = CGSize.zero
    private let startTime = ProcessInfo.processInfo.systemUptime

    /// Hook for the Slice 3 Metal preview renderer: called on `videoQueue` with each frame's
    /// textures, inside the frame's command buffer.
    var frameRenderer: ((MTLCommandBuffer, MTLTexture, MTLTexture) -> Void)?

    // GPU-completion state
    private let histogramLock = NSLock()
    private var lastPublishedHistogram = HistogramSample.empty

    private lazy var snapshotContext: CIContext = {
        if let metalDevice { return CIContext(mtlDevice: metalDevice, options: [.cacheIntermediates: false]) }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    override init() {
        let device = MTLCreateSystemDefaultDevice()
        metalDevice = device
        commandQueue = device?.makeCommandQueue()
        super.init()
        guard let device else { return }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache

        if let library = device.makeDefaultLibrary() {
            overlayPipeline = Self.makePipeline(named: "overlayKernel", library: library, device: device)
            histogramPipeline = Self.makePipeline(named: "histogramKernel", library: library, device: device)
            sharpnessPipeline = Self.makePipeline(named: "sharpnessKernel", library: library, device: device)
            loupePipeline = Self.makePipeline(named: "loupeKernel", library: library, device: device)
        }
        let histogramLength = 1024 * MemoryLayout<UInt32>.stride
        histogramBuffers = (0..<2).compactMap { _ in device.makeBuffer(length: histogramLength, options: .storageModeShared) }
        sharpnessBuffers = (0..<2).compactMap { _ in device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared) }
    }

    private static func makePipeline(named name: String, library: MTLLibrary, device: MTLDevice) -> MTLComputePipelineState? {
        guard let function = library.makeFunction(name: name) else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }

    // MARK: - Configuration (any thread)

    func updateConfig(_ change: (inout Config) -> Void) {
        stateLock.lock()
        change(&config)
        stateLock.unlock()
    }

    var currentConfig: Config {
        stateLock.lock()
        defer { stateLock.unlock() }
        return config
    }

    /// The overlay layer peaking and zebras are drawn into.
    func attachOverlay(_ layer: CAMetalLayer?) {
        stateLock.lock()
        overlayLayer = layer
        stateLock.unlock()
    }

    func attachLoupe(_ layer: CAMetalLayer?) {
        stateLock.lock()
        loupeLayer = layer
        stateLock.unlock()
    }

    /// Brightens peaking briefly (the focus-snap flash).
    func flashPeaking(duration: TimeInterval = 0.2) {
        stateLock.lock()
        flashUntil = ProcessInfo.processInfo.systemUptime + duration
        stateLock.unlock()
    }

    /// The next frame whose connection belongs to `deviceID` triggers `onFirstFrame` (lens switch fade).
    func expectFirstFrame(fromDeviceID deviceID: String) {
        stateLock.lock()
        expectedDeviceID = deviceID
        stateLock.unlock()
    }

    // MARK: - Snapshot for lens switches (Slice 1 §8)

    /// Blurred, display-oriented copy of the latest frame. Calls back on `videoQueue`.
    func makeSnapshot(maxDimension: CGFloat = 480, completion: @escaping (CGImage?) -> Void) {
        videoQueue.async { [weak self] in
            guard let self, let buffer = self.latestPixelBuffer else {
                completion(nil)
                return
            }
            let config = self.currentConfig
            var image = CIImage(cvPixelBuffer: buffer).oriented(Self.orientation(forQuarterTurns: config.quarterTurns))
            if config.mirrored {
                image = image.oriented(.upMirrored)
            }
            let longest = max(image.extent.width, image.extent.height)
            if longest > maxDimension, longest > 0 {
                let scale = maxDimension / longest
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            let extent = image.extent
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 8).cropped(to: extent)
            completion(self.snapshotContext.createCGImage(blurred, from: extent))
        }
    }

    static func orientation(forQuarterTurns turns: Int) -> CGImagePropertyOrientation {
        switch ((turns % 4) + 4) % 4 {
        case 1: return .right
        case 2: return .down
        case 3: return .left
        default: return .up
        }
    }

    /// Converts a display-uv rect to the matching buffer-uv rect (rotation maps rects to rects).
    static func bufferRect(forDisplayRect rect: CGRect, quarterTurns: Int, mirrored: Bool) -> CGRect {
        let a = RotationMath.bufferPoint(forDisplayPoint: CGPoint(x: rect.minX, y: rect.minY), quarterTurns: quarterTurns, mirrored: mirrored)
        let b = RotationMath.bufferPoint(forDisplayPoint: CGPoint(x: rect.maxX, y: rect.maxY), quarterTurns: quarterTurns, mirrored: mirrored)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestPixelBuffer = pixelBuffer
        frameIndex &+= 1
        let now = ProcessInfo.processInfo.systemUptime
        measureRate(now: now)

        let bufferSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if bufferSize != lastBufferSize {
            lastBufferSize = bufferSize
            onBufferSize?(bufferSize)
        }

        stateLock.lock()
        let config = self.config
        let overlay = overlayLayer
        let loupe = loupeLayer
        let flash = now < flashUntil ? Float((flashUntil - now) / 0.2) : 0
        var firstFrame = false
        if let expected = expectedDeviceID,
           let input = connection.inputPorts.first?.input as? AVCaptureDeviceInput,
           input.device.uniqueID == expected {
            expectedDeviceID = nil
            firstFrame = true
        }
        stateLock.unlock()
        if firstFrame { onFirstFrame?() }

        guard let commandQueue, let textureCache else { return }

        let overlayStride: UInt64 = config.thermal >= .serious ? 2 : 1
        let wantsOverlay = (config.peakingEnabled || config.zebrasEnabled)
            && overlay != nil && overlayPipeline != nil && frameIndex % overlayStride == 0
        let wantsClear = !(config.peakingEnabled || config.zebrasEnabled) && overlayHasContent && overlay != nil
        let histogramRate: Double = config.thermal >= .serious ? 10 : 30
        let wantsHistogram = config.histogramEnabled
            && histogramPipeline != nil
            && now - lastHistogramTime >= (1.0 / histogramRate) * 0.95
        let wantsSharpness = config.sharpnessEnabled && sharpnessPipeline != nil && onSharpness != nil
        let wantsLoupe = config.loupeEnabled && loupe != nil && loupePipeline != nil
        let wantsRenderer = frameRenderer != nil

        guard wantsOverlay || wantsClear || wantsHistogram || wantsSharpness || wantsLoupe || wantsRenderer else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        var retained: [CVMetalTexture] = []
        guard let luma = makeTexture(pixelBuffer, plane: 0, format: .r8Unorm, cache: textureCache) else { return }
        retained.append(luma.cvTexture)
        var chromaTexture: MTLTexture?
        if wantsHistogram || wantsLoupe || wantsRenderer,
           let chroma = makeTexture(pixelBuffer, plane: 1, format: .rg8Unorm, cache: textureCache) {
            retained.append(chroma.cvTexture)
            chromaTexture = chroma.texture
        }

        if wantsRenderer, let chromaTexture, let renderer = frameRenderer {
            renderer(commandBuffer, luma.texture, chromaTexture)
        }

        if wantsOverlay, let overlay, let pipeline = overlayPipeline {
            encodeOverlay(into: commandBuffer, layer: overlay, pipeline: pipeline, luma: luma.texture, config: config, flash: flash, time: Float(now - startTime))
        } else if wantsClear, let overlay {
            encodeClear(into: commandBuffer, layer: overlay)
        }

        if wantsLoupe, let loupe, let pipeline = loupePipeline, let chromaTexture {
            encodeLoupe(into: commandBuffer, layer: loupe, pipeline: pipeline, luma: luma.texture, chroma: chromaTexture, config: config)
        }

        var histogramBuffer: MTLBuffer?
        if wantsHistogram, let pipeline = histogramPipeline, let chromaTexture,
           histogramSlots.wait(timeout: .now()) == .success {
            let buffer = histogramBuffers[histogramBufferIndex]
            histogramBufferIndex = (histogramBufferIndex + 1) % histogramBuffers.count
            memset(buffer.contents(), 0, buffer.length)
            encodeHistogram(into: commandBuffer, pipeline: pipeline, luma: luma.texture, chroma: chromaTexture, bins: buffer)
            histogramBuffer = buffer
            lastHistogramTime = now
        }

        var sharpnessBuffer: MTLBuffer?
        if wantsSharpness, let pipeline = sharpnessPipeline, sharpnessSlots.wait(timeout: .now()) == .success {
            let buffer = sharpnessBuffers[sharpnessBufferIndex]
            sharpnessBufferIndex = (sharpnessBufferIndex + 1) % sharpnessBuffers.count
            memset(buffer.contents(), 0, buffer.length)
            encodeSharpness(into: commandBuffer, pipeline: pipeline, luma: luma.texture, energy: buffer, config: config)
            sharpnessBuffer = buffer
        }

        let histogramSemaphore = histogramSlots
        let sharpnessSemaphore = sharpnessSlots
        commandBuffer.addCompletedHandler { [weak self] _ in
            // Keep the CVMetalTextures alive until the GPU is done with them.
            withExtendedLifetime(retained) {}
            if let histogramBuffer {
                self?.publishHistogram(from: histogramBuffer)
                histogramSemaphore.signal()
            }
            if let sharpnessBuffer {
                let value = sharpnessBuffer.contents().load(as: UInt32.self)
                self?.onSharpness?(Double(value) / 4096)
                sharpnessSemaphore.signal()
            }
        }
        commandBuffer.commit()

        if frameIndex % 120 == 0 {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }

    // MARK: - Encoding

    private func encodeOverlay(into commandBuffer: MTLCommandBuffer, layer: CAMetalLayer, pipeline: MTLComputePipelineState,
                               luma: MTLTexture, config: Config, flash: Float, time: Float) {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let output = drawable.texture
        let displaySize = RotationMath.displaySize(
            forBufferSize: CGSize(width: luma.width, height: luma.height),
            quarterTurns: config.quarterTurns
        )
        let stepScale = Float(max(1, displaySize.width / CGFloat(max(output.width, 1))))
        var params = OverlayParams(
            quarterTurns: UInt32(((config.quarterTurns % 4) + 4) % 4),
            mirrored: config.mirrored ? 1 : 0,
            threshold: config.peakingThreshold,
            stepScale: stepScale,
            color: config.peakingColor,
            lumaTexel: SIMD2<Float>(1 / Float(luma.width), 1 / Float(luma.height)),
            peakingEnabled: config.peakingEnabled ? 1 : 0,
            zebrasEnabled: config.zebrasEnabled ? 1 : 0,
            zebraThreshold: config.zebraThreshold,
            time: time,
            flash: flash
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<OverlayParams>.stride, index: 0)
        dispatch(encoder, pipeline: pipeline, width: output.width, height: output.height)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        overlayHasContent = true
    }

    private func encodeClear(into commandBuffer: MTLCommandBuffer, layer: CAMetalLayer) {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        overlayHasContent = false
    }

    private func encodeLoupe(into commandBuffer: MTLCommandBuffer, layer: CAMetalLayer, pipeline: MTLComputePipelineState,
                             luma: MTLTexture, chroma: MTLTexture, config: Config) {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let output = drawable.texture
        let halfWidth = config.loupeWindow.width / 2
        let halfHeight = config.loupeWindow.height / 2
        // Keep the window inside the frame.
        let center = CGPoint(
            x: ExposureMath.clamp(config.loupeCenter.x, halfWidth, 1 - halfWidth),
            y: ExposureMath.clamp(config.loupeCenter.y, halfHeight, 1 - halfHeight)
        )
        var params = LoupeParams(
            center: SIMD2<Float>(Float(center.x), Float(center.y)),
            windowSize: SIMD2<Float>(Float(config.loupeWindow.width), Float(config.loupeWindow.height)),
            quarterTurns: UInt32(((config.quarterTurns % 4) + 4) % 4),
            mirrored: config.mirrored ? 1 : 0,
            nearest: config.loupeNearest ? 1 : 0,
            threshold: config.peakingThreshold,
            peakColor: config.peakingColor,
            lumaTexel: SIMD2<Float>(1 / Float(luma.width), 1 / Float(luma.height)),
            peaking: config.peakingEnabled ? 1 : 0
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<LoupeParams>.stride, index: 0)
        dispatch(encoder, pipeline: pipeline, width: output.width, height: output.height)
        encoder.endEncoding()
        commandBuffer.present(drawable)
    }

    private func encodeHistogram(into commandBuffer: MTLCommandBuffer, pipeline: MTLComputePipelineState, luma: MTLTexture, chroma: MTLTexture, bins: MTLBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var params = HistogramParams(width: UInt32(histogramGrid.width), height: UInt32(histogramGrid.height))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setBuffer(bins, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<HistogramParams>.stride, index: 1)
        dispatch(encoder, pipeline: pipeline, width: histogramGrid.width, height: histogramGrid.height)
        encoder.endEncoding()
    }

    private func encodeSharpness(into commandBuffer: MTLCommandBuffer, pipeline: MTLComputePipelineState, luma: MTLTexture, energy: MTLBuffer, config: Config) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let rect = Self.bufferRect(forDisplayRect: config.sharpnessROI, quarterTurns: config.quarterTurns, mirrored: config.mirrored)
        var params = SharpnessParams(
            origin: SIMD2<Float>(Float(rect.minX), Float(rect.minY)),
            size: SIMD2<Float>(Float(rect.width), Float(rect.height)),
            gridWidth: UInt32(sharpnessGrid),
            gridHeight: UInt32(sharpnessGrid),
            lumaTexel: SIMD2<Float>(1 / Float(luma.width), 1 / Float(luma.height))
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setBuffer(energy, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<SharpnessParams>.stride, index: 1)
        dispatch(encoder, pipeline: pipeline, width: sharpnessGrid, height: sharpnessGrid)
        encoder.endEncoding()
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let threadWidth = max(1, pipeline.threadExecutionWidth)
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        let perGroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let groups = MTLSize(
            width: (width + threadWidth - 1) / threadWidth,
            height: (height + threadHeight - 1) / threadHeight,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: perGroup)
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> (texture: MTLTexture, cvTexture: CVMetalTexture)? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > plane else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, format, width, height, plane, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return (texture, cvTexture)
    }

    // MARK: - Histogram readback

    private func publishHistogram(from buffer: MTLBuffer) {
        let pointer = buffer.contents().bindMemory(to: UInt32.self, capacity: 1024)
        let counts = UnsafeBufferPointer(start: pointer, count: 1024)
        let sample = Self.normalise(counts: Array(counts), samples: histogramGrid.width * histogramGrid.height)

        histogramLock.lock()
        let changed = sample.maxDifference(to: lastPublishedHistogram) > 0.01
            || abs(sample.highlightClip - lastPublishedHistogram.highlightClip) > 0.001
            || abs(sample.shadowClip - lastPublishedHistogram.shadowClip) > 0.001
        if changed { lastPublishedHistogram = sample }
        histogramLock.unlock()

        if changed { onHistogram?(sample) }
    }

    /// Converts raw bin counts (`[r 256 | g 256 | b 256 | luma 256]`) into a normalised sample.
    static func normalise(counts: [UInt32], samples: Int) -> HistogramSample {
        guard counts.count >= 1024 else { return .empty }
        func channel(_ offset: Int) -> [Float] {
            let slice = counts[offset..<(offset + 256)].map { Float($0) }
            let peak = max(slice.max() ?? 1, 1)
            return slice.map { $0 / peak }
        }
        let total = Float(max(samples, 1))
        return HistogramSample(
            red: channel(0),
            green: channel(256),
            blue: channel(512),
            luma: channel(768),
            shadowClip: Float(counts[768]) / total,
            highlightClip: Float(counts[1023]) / total
        )
    }

    private func measureRate(now: TimeInterval) {
        if rateWindowStart == 0 { rateWindowStart = now }
        rateWindowFrames += 1
        let elapsed = now - rateWindowStart
        if elapsed >= 1 {
            onFeedRate?(Double(rateWindowFrames) / elapsed)
            rateWindowStart = now
            rateWindowFrames = 0
        }
    }
}
