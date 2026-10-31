import XCTest
@testable import ManualCameraApp

/// Capture size and quality prioritization (WWDC26 "Implement high resolution photo capture"):
/// 12 MP at any prioritization, 48 MP needs balanced or quality, fused 24 MP needs quality, and a
/// locked manual exposure is exact only at speed (12 MP).
final class PhotoResolutionTests: XCTestCase {

    private let iPhone15Pro: [(width: Int32, height: Int32)] = [(4032, 3024), (5712, 4284), (8064, 6048)]
    private let iPhone14Pro: [(width: Int32, height: Int32)] = [(4032, 3024), (8064, 6048)]

    private func choose(
        _ supported: [(width: Int32, height: Int32)],
        _ format: CaptureFormat,
        heif: PhotoSize = .mp24,
        custom: Bool = false,
        exact: Bool = false,
        bayer: Bool = false,
        max: PhotoResolution.Prioritization = .quality
    ) -> PhotoResolution.Choice {
        PhotoResolution.choose(
            supported: supported, format: format, heifSize: heif, customExposure: custom,
            exactManualExposure: exact, bayerRaw: bayer, maxPrioritization: max
        )
    }

    func testHEIFDefaultsTo24MegapixelsAtQuality() {
        XCTAssertEqual(choose(iPhone15Pro, .heif), .init(width: 5712, height: 4284, prioritization: .quality))
    }

    func testRawIs48MegapixelsAtBalanced() {
        XCTAssertEqual(choose(iPhone15Pro, .raw), .init(width: 8064, height: 6048, prioritization: .balanced))
        XCTAssertEqual(choose(iPhone15Pro, .rawPlusHEIF), .init(width: 8064, height: 6048, prioritization: .balanced))
    }

    func testManualExposureKeepsResolutionByDefault() {
        XCTAssertEqual(choose(iPhone15Pro, .heif, custom: true), .init(width: 5712, height: 4284, prioritization: .quality))
        XCTAssertEqual(choose(iPhone15Pro, .raw, custom: true), .init(width: 8064, height: 6048, prioritization: .balanced))
    }

    func testExactManualExposureUses12MegapixelsAtSpeed() {
        XCTAssertEqual(choose(iPhone15Pro, .raw, custom: true, exact: true), .init(width: 4032, height: 3024, prioritization: .speed))
        XCTAssertEqual(choose(iPhone15Pro, .heif, custom: true, exact: true), .init(width: 4032, height: 3024, prioritization: .speed))
        // Exact exposure only matters when the exposure is locked.
        XCTAssertEqual(choose(iPhone15Pro, .heif, custom: false, exact: true).width, 5712)
    }

    func testBayerRawIs12Megapixels() {
        XCTAssertEqual(choose(iPhone15Pro, .raw, bayer: true), .init(width: 4032, height: 3024, prioritization: .speed))
    }

    func testOtherHEIFSizes() {
        XCTAssertEqual(choose(iPhone15Pro, .heif, heif: .mp12), .init(width: 4032, height: 3024, prioritization: .balanced))
        XCTAssertEqual(choose(iPhone15Pro, .heif, heif: .mp48), .init(width: 8064, height: 6048, prioritization: .quality))
    }

    func testPhonesWithout24MegapixelsFallBackTo12() {
        XCTAssertEqual(choose(iPhone14Pro, .heif), .init(width: 4032, height: 3024, prioritization: .balanced))
        XCTAssertEqual(choose(iPhone14Pro, .raw).width, 8064)
    }

    func testPrioritizationLimitDecidesTheSize() {
        // 24 MP needs quality; an output limited to balanced takes 12 MP.
        XCTAssertEqual(choose(iPhone15Pro, .heif, max: .balanced), .init(width: 4032, height: 3024, prioritization: .balanced))
        XCTAssertEqual(choose(iPhone15Pro, .raw, max: .speed), .init(width: 4032, height: 3024, prioritization: .speed))
    }

    func testNoSupportedSizes() {
        XCTAssertEqual(choose([], .heif), .init(width: 4032, height: 3024, prioritization: .balanced))
    }

    func testFrontCamera12MegapixelsOnly() {
        XCTAssertEqual(choose([(4032, 3024)], .heif), .init(width: 4032, height: 3024, prioritization: .balanced))
        XCTAssertEqual(choose([(4032, 3024)], .raw), .init(width: 4032, height: 3024, prioritization: .balanced))
    }
}
