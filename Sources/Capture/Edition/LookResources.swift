import CoreGraphics
import Foundation
import ImageIO
import Metal
import os

/// Swift mirror of `LookParams` in Shaders.metal.
struct LookParams {
    var shaperMax: Float
    var shaperInvExp: Float
    var lutSize: Float
    var grainAmplitude: Float
    var grainScale: Float
    var padding0: Float = 0
    var origin: SIMD2<Float>
    var octaveWeights: SIMD4<Float>
    var offset0: SIMD2<Float>
    var offset1: SIMD2<Float>
    var offset2: SIMD2<Float>
    var padding1: SIMD2<Float> = .zero

    static func make(grainAmplitude: Float, grainScale: Float, seed: UInt32, lutSize: Int, origin: SIMD2<Float> = .zero) -> LookParams {
        let offsets = GrainMath.octaveOffsets(seed: seed)
        let weights = LookConstants.grainOctaveWeights + [0, 0, 0]
        return LookParams(
            shaperMax: LookConstants.shaperMaxLinear,
            shaperInvExp: 1 / LookConstants.shaperExponent,
            lutSize: Float(max(lutSize, 2)),
            grainAmplitude: grainAmplitude,
            grainScale: grainScale,
            origin: origin,
            octaveWeights: SIMD4<Float>(weights[0], weights[1], weights[2], 0),
            offset0: offsets[0],
            offset1: offsets[1],
            offset2: offsets[2]
        )
    }
}

/// The LUT and grain textures plus the compute pipelines for the look. Loaded once, off the main
/// thread, the first time the Edition is turned on (parsing the 65³ cube takes a few hundred ms).
final class LookResources: @unchecked Sendable {

    static let shared = LookResources()

    private let lock = NSLock()
    private let logger = Logger(subsystem: "ManualCameraApp", category: "Look")
    private var loaded = false
    private(set) var device: MTLDevice?
    /// LUT textures by `LookDescriptor.id`, loaded on first use.
    private var luts: [String: MTLTexture] = [:]
    private(set) var noise: MTLTexture?
    private(set) var stillPipeline: MTLComputePipelineState?
    private(set) var previewPipeline: MTLComputePipelineState?

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loaded && luts[LookDescriptor.defaultID] != nil && noise != nil && stillPipeline != nil
    }

    /// The LUT for a look. With `loadIfNeeded` false it never parses (safe on the video queue) and
    /// returns nil until `preload` has run; callers then fall back to the base look.
    func lut(for id: String, loadIfNeeded: Bool = true) -> MTLTexture? {
        lock.lock()
        if let texture = luts[id] {
            lock.unlock()
            return texture
        }
        let device = self.device
        lock.unlock()
        guard loadIfNeeded, let device else { return nil }
        let descriptor = LookDescriptor.find(id)
        guard let texture = Self.loadLUT(descriptor, device: device, logger: logger) else { return nil }
        lock.lock()
        luts[descriptor.id] = texture
        lock.unlock()
        return texture
    }

    /// Loads a look's LUT ahead of use (call off the main thread).
    @discardableResult
    func preload(_ id: String) -> Bool {
        lut(for: id) != nil
    }

    private static func loadLUT(_ descriptor: LookDescriptor, device: MTLDevice, logger: Logger) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: descriptor.resource, withExtension: "cube") else {
            logger.error("\(descriptor.resource, privacy: .public).cube missing from the bundle")
            return nil
        }
        do {
            let table = try CubeLUT.parse(String(contentsOf: url, encoding: .utf8))
            return makeLUTTexture(table, device: device)
        } catch {
            logger.error("Look \(descriptor.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Loads everything (idempotent). Call from a background queue.
    @discardableResult
    func load(device: MTLDevice? = MTLCreateSystemDefaultDevice()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if loaded { return luts[LookDescriptor.defaultID] != nil }
        loaded = true
        guard let device else { return false }
        self.device = device
        do {
            if let base = Self.loadLUT(LookDescriptor.find(LookDescriptor.defaultID), device: device, logger: logger) {
                luts[LookDescriptor.defaultID] = base
            }
            if let noiseURL = Bundle.main.url(forResource: "BlueNoise64", withExtension: "png") {
                noise = Self.makeNoiseTexture(url: noiseURL, device: device)
            }
            if noise == nil { logger.error("BlueNoise64.png missing or unreadable") }
            if let library = device.makeDefaultLibrary() {
                if let function = library.makeFunction(name: "lookStillKernel") {
                    stillPipeline = try device.makeComputePipelineState(function: function)
                }
                if let function = library.makeFunction(name: "lookPreviewKernel") {
                    previewPipeline = try device.makeComputePipelineState(function: function)
                }
            }
        } catch {
            logger.error("Look resources failed: \(error.localizedDescription, privacy: .public)")
        }
        return luts[LookDescriptor.defaultID] != nil
    }

    /// 65³ RGBA half-float 3D texture, red along x.
    static func makeLUTTexture(_ table: CubeLUT.Table, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        // Half floats: filterable on every Apple GPU (32-bit float filtering is not guaranteed).
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = table.size
        descriptor.height = table.size
        descriptor.depth = table.size
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let halves = table.rgba.map { Self.halfBits($0) }
        let bytesPerRow = table.size * 4 * MemoryLayout<UInt16>.stride
        halves.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, table.size, table.size, table.size),
                mipmapLevel: 0,
                slice: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerRow * table.size
            )
        }
        return texture
    }

    /// The blue-noise tile as an `r8Unorm` texture. Decoded with ImageIO into an 8-bit grey buffer
    /// (rather than `MTKTextureLoader`), so Xcode's PNG optimisation or a colour profile can never
    /// change the noise values or the channel layout.
    static func makeNoiseTexture(url: URL, device: MTLDevice) -> MTLTexture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: base, bytesPerRow: width)
        }
        return texture
    }

    /// IEEE 754 binary16 bits for a Float (round to nearest), without relying on `Float16`, which
    /// is unavailable on Intel-Mac simulators.
    static func halfBits(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xFF) - 127 + 15
        var mantissa = bits & 0x7F_FFFF
        if exponent >= 31 {
            return sign | 0x7C00 // overflow → infinity (NaN is not expected in the LUT)
        }
        if exponent <= 0 {
            if exponent < -10 { return sign }
            mantissa |= 0x80_0000
            let shift = UInt32(14 - exponent)
            let rounded = (mantissa + (1 << (shift - 1))) >> shift
            return sign | UInt16(rounded)
        }
        let rounded = mantissa + 0x1000
        if rounded & 0x80_0000 != 0 {
            return sign | UInt16((exponent + 1) << 10)
        }
        return sign | UInt16(exponent << 10) | UInt16(rounded >> 13)
    }

    static func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let threadWidth = max(1, pipeline.threadExecutionWidth)
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + threadWidth - 1) / threadWidth, height: (height + threadHeight - 1) / threadHeight, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
    }
}
