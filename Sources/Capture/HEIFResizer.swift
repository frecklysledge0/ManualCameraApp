import CoreImage
import Foundation
import ImageIO

/// Scales a captured HEIF down to the chosen photo size. Used for RAW+HEIF: both files come from
/// one capture at the sensor's full resolution (iOS uses one size for the pair), so the DNG keeps
/// 48 MP and the HEIF is resized to 24 MP (or 12 MP) afterwards, off the capture path.
enum HEIFResizer {

    private static let context = CIContext(options: [.cacheIntermediates: false, .name: "HEIFResizer"])

    /// Returns `item` with its processed data scaled to at most `maxPixels` (unchanged when it is
    /// already that small or anything fails, so a photo is never lost).
    static func resize(_ item: CaptureItem, maxPixels: Int) -> CaptureItem {
        guard maxPixels > 0,
              let data = item.processedData,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let image = CIImage(data: data) else { return item }
        let extent = image.extent
        let pixels = Double(extent.width * extent.height)
        guard pixels > Double(maxPixels) * 1.02 else { return item }
        let factor = (Double(maxPixels) / pixels).squareRoot()
        let target = CGRect(x: 0, y: 0, width: (extent.width * factor).rounded(.down), height: (extent.height * factor).rounded(.down))
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1.0])
            .cropped(to: target)
            .settingProperties(outputProperties(from: properties))
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let encoded = context.heifRepresentation(of: scaled, format: .RGBA8, colorSpace: space, options: [quality: 0.92]) else {
            return item
        }
        var resized = item
        resized.processedData = encoded
        resized.processedType = "public.heic"
        return resized
    }

    /// Camera metadata and orientation kept (the pixels are not rotated), size keys dropped.
    static func outputProperties(from source: [String: Any]) -> [String: Any] {
        var properties = source
        properties.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        return properties
    }
}
