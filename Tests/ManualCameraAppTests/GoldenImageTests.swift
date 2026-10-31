import CoreImage
import ImageIO
import XCTest
@testable import ManualCameraApp

/// Golden-image tests for MF Natural Colour (Slice 3 §10).
///
/// The reference set is supplied by the photographer, not generated: put pairs of files in
/// `Tests/Golden/` (`<name>.dng` and the approved `<name>.png`, 8-bit sRGB, any size) and add the
/// folder to the test target as a folder reference. Each DNG is developed with grain off at
/// native framing, scaled to the reference size and compared with CIEDE2000. Without a reference
/// set these tests are skipped.
final class GoldenImageTests: XCTestCase {

    /// Mean ΔE00 above this means the look drifted visibly.
    private let meanLimit = 1.0
    /// The worst 1% of pixels may differ more (demosaic and noise-reduction changes).
    private let p99Limit = 3.0

    func testDevelopedImagesMatchReferences() throws {
        let pairs = Self.referencePairs()
        guard !pairs.isEmpty else {
            throw XCTSkip("No golden set in Tests/Golden (see the class comment).")
        }
        let developer = EditionDeveloper()
        for (dng, png) in pairs {
            let item = CaptureItem(id: UUID(), processedData: nil, processedType: "public.heic", rawFileURL: dng)
            let developed = try developer.develop(item, options: .init(framing: .native, grain: .off, iso: 100))
            let output = try XCTUnwrap(developed.processedData, dng.lastPathComponent)
            let reference = try XCTUnwrap(Self.pixels(of: png, size: nil), png.lastPathComponent)
            let candidate = try XCTUnwrap(Self.pixels(of: output, size: reference.size), dng.lastPathComponent)
            var errors: [Double] = []
            errors.reserveCapacity(reference.rgb.count / 3)
            for index in stride(from: 0, to: reference.rgb.count, by: 3) {
                let a = DeltaE.lab(fromSRGB: reference.rgb[index], reference.rgb[index + 1], reference.rgb[index + 2])
                let b = DeltaE.lab(fromSRGB: candidate.rgb[index], candidate.rgb[index + 1], candidate.rgb[index + 2])
                errors.append(DeltaE.ciede2000(a, b))
            }
            errors.sort()
            let mean = errors.reduce(0, +) / Double(max(errors.count, 1))
            let p99 = errors[min(errors.count - 1, Int(Double(errors.count) * 0.99))]
            XCTAssertLessThan(mean, meanLimit, "\(dng.lastPathComponent): mean ΔE00 \(mean)")
            XCTAssertLessThan(p99, p99Limit, "\(dng.lastPathComponent): p99 ΔE00 \(p99)")
        }
    }

    // MARK: - Helpers

    private static func referencePairs() -> [(URL, URL)] {
        let bundle = Bundle(for: GoldenImageTests.self)
        guard let folder = bundle.url(forResource: "Golden", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension.lowercased() == "dng" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { dng in
                let png = dng.deletingPathExtension().appendingPathExtension("png")
                return FileManager.default.fileExists(atPath: png.path) ? (dng, png) : nil
            }
    }

    private struct Pixels {
        var size: CGSize
        /// sRGB-encoded 0…1, RGB interleaved.
        var rgb: [Double]
    }

    private static func pixels(of url: URL, size: CGSize?) -> Pixels? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixels(of: source, size: size)
    }

    private static func pixels(of data: Data, size: CGSize?) -> Pixels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixels(of: source, size: size)
    }

    /// Decodes and renders into 8-bit sRGB at `size` (or the image's own size).
    private static func pixels(of source: CGImageSource, size: CGSize?) -> Pixels? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = Int(size?.width ?? CGFloat(image.width))
        let height = Int(size?.height ?? CGFloat(image.height))
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb: [Double] = []
        rgb.reserveCapacity(width * height * 3)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            rgb.append(Double(bytes[index]) / 255)
            rgb.append(Double(bytes[index + 1]) / 255)
            rgb.append(Double(bytes[index + 2]) / 255)
        }
        return Pixels(size: CGSize(width: width, height: height), rgb: rgb)
    }
}
