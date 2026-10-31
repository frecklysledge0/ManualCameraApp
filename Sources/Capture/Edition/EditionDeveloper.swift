import CoreImage
import Foundation
import ImageIO
import Metal
import os

/// Runs `lookStillKernel` inside Core Image, so CI handles tiling and memory for 48 MP images.
/// The textures and pipeline come from `LookResources.shared`; only numbers travel in `arguments`.
final class MFLookKernel: CIImageProcessorKernel {

    enum Argument {
        static let amplitude = "amplitude"
        static let scale = "scale"
        static let seed = "seed"
        static let look = "look"
    }

    enum KernelError: Error {
        case resourcesMissing
        case textureUnavailable
    }

    override class var outputFormat: CIFormat { .RGBAh }

    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        outputRect
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        let resources = LookResources.shared
        let lookID = arguments?[Argument.look] as? String ?? LookDescriptor.defaultID
        guard let pipeline = resources.stillPipeline,
              let lut = resources.lut(for: lookID) ?? resources.lut(for: LookDescriptor.defaultID),
              let noise = resources.noise else {
            throw KernelError.resourcesMissing
        }
        guard let input = inputs?.first,
              let source = input.metalTexture,
              let destination = output.metalTexture,
              let commandBuffer = output.metalCommandBuffer,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw KernelError.textureUnavailable
        }
        let amplitude = (arguments?[Argument.amplitude] as? NSNumber)?.floatValue ?? 0
        let scale = (arguments?[Argument.scale] as? NSNumber)?.floatValue ?? 1
        let seed = (arguments?[Argument.seed] as? NSNumber)?.uint32Value ?? 0
        var params = LookParams.make(
            grainAmplitude: amplitude,
            grainScale: scale,
            seed: seed,
            lutSize: lut.width,
            origin: SIMD2<Float>(Float(output.region.minX), Float(output.region.minY))
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setTexture(lut, index: 2)
        encoder.setTexture(noise, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<LookParams>.stride, index: 0)
        LookResources.dispatch(encoder, pipeline: pipeline, width: destination.width, height: destination.height)
        encoder.endEncoding()
    }
}

/// Develops an Edition shot (Slice 3 §6): RAW → `CIRAWFilter` (no sharpening, gentle local tone
/// mapping) → framing crop → MF Natural Colour + grain → 10-bit HEIF in Display P3. When the shot
/// has no RAW, the look is applied to the processed HEIF instead (fallback).
final class EditionDeveloper: @unchecked Sendable {

    struct Options: Sendable {
        var framing: FramingMode
        var grain: GrainLevel
        var iso: Float
        var lookID: String = LookDescriptor.defaultID
        /// Output pixel count; larger crops are scaled down (0 = keep the full resolution).
        var maxPixels: Int = 0
    }

    enum DevelopError: Error {
        case noSource
        case lookUnavailable
        case renderFailed
    }

    private let context: CIContext
    private let logger = Logger(subsystem: "ManualCameraApp", category: "Edition")
    private let outputSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    init(device: MTLDevice? = LookResources.shared.device ?? MTLCreateSystemDefaultDevice()) {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .name: "MFEdition"
        ]
        if let device {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    func develop(_ item: CaptureItem, options: Options) throws -> CaptureItem {
        let start = ProcessInfo.processInfo.systemUptime
        guard LookResources.shared.isReady || LookResources.shared.load() else {
            throw DevelopError.lookUnavailable
        }

        var image: CIImage
        var properties: [String: Any] = [:]
        var fromRaw = false
        if let rawURL = item.rawFileURL, let raw = CIRAWFilter(imageURL: rawURL), let developed = Self.configure(raw).outputImage {
            image = developed
            fromRaw = true
            properties = Self.properties(of: rawURL)
        } else if let data = item.processedData,
                  let processed = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            // Fallback: Apple's sharpening in the HEIF can't be undone, but colour and grain apply.
            image = processed
            properties = processed.properties
        } else {
            throw DevelopError.noSource
        }

        // Framing (Slice 3 §5): the developed HEIF is cropped; the DNG stays full-frame.
        let extent = image.extent.integral
        let crop = FramingMath.cropRect(for: options.framing, in: extent.size).offsetBy(dx: extent.minX, dy: extent.minY)
        image = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        // Output size: scale the crop down to the chosen photo size (Lanczos), before the look so
        // grain is generated at the final resolution.
        let cropPixels = Double(crop.width * crop.height)
        if options.maxPixels > 0, cropPixels > Double(options.maxPixels) * 1.02 {
            let factor = (Double(options.maxPixels) / cropPixels).squareRoot()
            let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: factor,
                kCIInputAspectRatioKey: 1.0
            ])
            let target = CGRect(x: 0, y: 0, width: (crop.width * factor).rounded(.down), height: (crop.height * factor).rounded(.down))
            image = scaled.cropped(to: target)
        }
        let outputHeight = image.extent.height

        let amplitude = GrainMath.amplitude(for: options.grain, iso: options.iso)
        let scale = GrainMath.scale(forImageHeight: outputHeight, level: options.grain)
        let seed = GrainMath.seed(for: item.id)
        image = try MFLookKernel.apply(
            withExtent: image.extent,
            inputs: [image],
            arguments: [
                MFLookKernel.Argument.amplitude: NSNumber(value: amplitude),
                MFLookKernel.Argument.scale: NSNumber(value: scale),
                MFLookKernel.Argument.seed: NSNumber(value: seed),
                MFLookKernel.Argument.look: options.lookID
            ]
        )

        image = image.settingProperties(Self.outputProperties(from: properties))
        let data: Data
        do {
            data = try context.heif10Representation(of: image, colorSpace: outputSpace, options: [:])
        } catch {
            guard let fallback = context.heifRepresentation(of: image, format: .RGBA8, colorSpace: outputSpace, options: [:]) else {
                throw DevelopError.renderFailed
            }
            data = fallback
        }

        var developed = item
        developed.processedData = data
        developed.processedType = "public.heic"
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        logger.info("Developed \(Int(image.extent.width))×\(Int(image.extent.height)) \(options.lookID, privacy: .public) from \(fromRaw ? "RAW" : "HEIF", privacy: .public) in \(elapsed, format: .fixed(precision: 0)) ms")
        return developed
    }

    /// No over-sharpening, reduced local tone mapping, a gentle base curve and low luminance noise
    /// reduction (Slice 3 §6). Each property is set only when the RAW supports it.
    private static func configure(_ raw: CIRAWFilter) -> CIRAWFilter {
        if raw.isSharpnessSupported { raw.sharpnessAmount = LookConstants.sharpnessAmount }
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = LookConstants.localToneMapAmount }
        raw.boostAmount = LookConstants.boostAmount
        if raw.isLuminanceNoiseReductionSupported {
            raw.luminanceNoiseReductionAmount = LookConstants.luminanceNoiseReductionAmount
        }
        return raw
    }

    private static func properties(of url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return [:]
        }
        return properties
    }

    /// Camera metadata kept, orientation reset (the develop is already upright), size keys dropped
    /// (the crop changes them), and the Edition's software tag added.
    static func outputProperties(from source: [String: Any]) -> [String: Any] {
        var properties = source
        properties[kCGImagePropertyOrientation as String] = 1
        properties.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        properties.removeValue(forKey: kCGImagePropertyDNGDictionary as String)
        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFSoftware as String] = Branding.editionSoftwareTag
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        properties[kCGImagePropertyTIFFDictionary as String] = tiff
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        return properties
    }
}
