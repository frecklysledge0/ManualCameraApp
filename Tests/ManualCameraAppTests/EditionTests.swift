import CoreGraphics
import CryptoKit
import ImageIO
import XCTest
@testable import ManualCameraApp

/// Slice 3 §10 unit tests: framing crops, grain maths, the LUT file and its parser, half-float
/// packing, CIEDE2000 and the theme rules that keep every value in one place on screen.
final class EditionTests: XCTestCase {

    // MARK: - Framing (§5)

    func testSquareCropOfLandscapeFrame() {
        let crop = FramingMath.cropRect(for: .square, in: CGSize(width: 8064, height: 6048))
        XCTAssertEqual(crop, CGRect(x: 1008, y: 0, width: 6048, height: 6048))
    }

    func testXPanCropKeepsTheLongSide() {
        let crop = FramingMath.cropRect(for: .xpan, in: CGSize(width: 8064, height: 6048))
        XCTAssertEqual(crop.width, 8064)
        XCTAssertEqual(crop.height, 2977) // 8064 × 24 / 65 ≈ 2977.48, rounded down
        XCTAssertEqual(crop.minY, 1535) // (6048 − 2977) / 2, rounded down
    }

    func testPortraitCropsAreTurnedOnEnd() {
        let square = FramingMath.cropRect(for: .square, in: CGSize(width: 6048, height: 8064))
        XCTAssertEqual(square.size, CGSize(width: 6048, height: 6048))
        let xpan = FramingMath.cropRect(for: .xpan, in: CGSize(width: 6048, height: 8064))
        XCTAssertEqual(xpan.size, CGSize(width: 2977, height: 8064))
    }

    func testNativeFramingIsTheWholeFrame() {
        let size = CGSize(width: 4032, height: 3024)
        XCTAssertEqual(FramingMath.cropRect(for: .native, in: size), CGRect(origin: .zero, size: size))
    }

    func testCropsStayInsideTheImage() {
        for mode in FramingMode.allCases {
            for size in [CGSize(width: 4032, height: 3024), CGSize(width: 3024, height: 4032), CGSize(width: 300, height: 400), CGSize(width: 1, height: 1)] {
                let crop = FramingMath.cropRect(for: mode, in: size)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(crop), "\(mode) in \(size)")
                XCTAssertGreaterThan(crop.width, 0)
                XCTAssertGreaterThan(crop.height, 0)
            }
        }
    }

    func testFramingLabels() {
        XCTAssertEqual(FramingMode.native.label, "4:3")
        XCTAssertEqual(FramingMode.square.label, "1:1")
        XCTAssertEqual(FramingMode.xpan.label, "XPAN")
    }

    // MARK: - Grain (§6 step 4)

    func testGrainScaleIsProportionalToOutputHeight() {
        let full = GrainMath.scale(forImageHeight: 6048, level: .fine)
        let half = GrainMath.scale(forImageHeight: 3024, level: .fine)
        XCTAssertEqual(full / half, 2, accuracy: 0.0001)
        XCTAssertGreaterThan(GrainMath.scale(forImageHeight: 6048, level: .medium), full)
    }

    func testGrainAmplitudeRisesWithISOAndIsCapped() {
        XCTAssertEqual(GrainMath.amplitude(for: .off, iso: 3200), 0)
        let base = GrainMath.amplitude(for: .fine, iso: 100)
        XCTAssertEqual(base, LookConstants.grainFineAmplitude, accuracy: 1e-6)
        XCTAssertGreaterThan(GrainMath.amplitude(for: .fine, iso: 800), base)
        XCTAssertEqual(GrainMath.isoBoost(iso: 50), 1, accuracy: 1e-6)
        XCTAssertEqual(GrainMath.isoBoost(iso: 1_000_000), LookConstants.grainISOBoostMax, accuracy: 1e-6)
    }

    func testGrainSeedIsDeterministicPerPhoto() {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        XCTAssertEqual(GrainMath.seed(for: id), GrainMath.seed(for: id))
        XCTAssertNotEqual(GrainMath.seed(for: id), GrainMath.seed(for: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FE")!))
    }

    func testOctaveOffsetsAreDeterministicAndInRange() {
        let a = GrainMath.octaveOffsets(seed: 12345)
        XCTAssertEqual(a, GrainMath.octaveOffsets(seed: 12345))
        XCTAssertNotEqual(a, GrainMath.octaveOffsets(seed: 54321))
        XCTAssertEqual(a.count, 3)
        for offset in a + GrainMath.octaveOffsets(seed: 0) {
            XCTAssertGreaterThanOrEqual(offset.x, 0)
            XCTAssertLessThan(offset.x, 1)
            XCTAssertGreaterThanOrEqual(offset.y, 0)
            XCTAssertLessThan(offset.y, 1)
        }
    }

    // MARK: - LUT (§6 step 3)

    func testCubeParserReadsASmallTable() throws {
        let text = """
        TITLE "test"
        # source-sha256: abc123
        LUT_3D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 1 1 1
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let table = try CubeLUT.parse(text)
        XCTAssertEqual(table.size, 2)
        XCTAssertEqual(table.sourceHash, "abc123")
        XCTAssertEqual(table.rgba.count, 2 * 2 * 2 * 4)
        // Red fastest: entry 1 is (1, 0, 0), entry 2 is (0, 1, 0).
        XCTAssertEqual(Array(table.rgba[4..<8]), [1, 0, 0, 1])
        XCTAssertEqual(Array(table.rgba[8..<12]), [0, 1, 0, 1])
    }

    func testCubeParserRejectsBadTables() {
        XCTAssertThrowsError(try CubeLUT.parse("0 0 0\n1 1 1\n")) { error in
            XCTAssertEqual(error as? CubeLUT.ParseError, .missingSize)
        }
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n")) { error in
            XCTAssertEqual(error as? CubeLUT.ParseError, .wrongCount(expected: 8, found: 1))
        }
    }

    func testBundledLUTMatchesTheGeneratedConstants() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "MFNaturalColour", withExtension: "cube"), "MFNaturalColour.cube is not in the app bundle")
        let table = try CubeLUT.parse(String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(table.size, LookConstants.lutSize)
        XCTAssertEqual(table.sourceHash, LookConstants.sourceHash)
        for value in table.rgba {
            XCTAssertTrue(value.isFinite)
        }
    }

    func testBundledLookJSONMatchesTheGeneratedConstants() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "look", withExtension: "json"), "look.json is not in the app bundle")
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, LookConstants.sourceHash, "look.json changed: re-run tools/look/make_look.py")
    }

    func testBundledAssetsArePresent() {
        XCTAssertNotNil(Bundle.main.url(forResource: "BlueNoise64", withExtension: "png"))
        XCTAssertNotNil(Bundle.main.url(forResource: "LeafShutter", withExtension: "caf"))
    }

    func testLookParamsLayoutMatchesTheShader() {
        // Shaders.metal `LookParams` is 80 bytes; the Swift mirror must match exactly.
        XCTAssertEqual(MemoryLayout<LookParams>.size, 80)
        XCTAssertEqual(MemoryLayout<LookParams>.stride, 80)
        XCTAssertEqual(MemoryLayout<LookParams>.offset(of: \LookParams.origin), 24)
        XCTAssertEqual(MemoryLayout<LookParams>.offset(of: \LookParams.octaveWeights), 32)
        XCTAssertEqual(MemoryLayout<LookParams>.offset(of: \LookParams.offset0), 48)
    }

    // MARK: - Half floats

    func testHalfBitsMatchIEEE754() {
        let cases: [(Float, UInt16)] = [
            (0, 0x0000), (1, 0x3C00), (0.5, 0x3800), (-2, 0xC000), (65504, 0x7BFF),
            (0.1, 0x2E66), (1.0 / 3.0, 0x3555), (6.103515625e-05, 0x0400),
            (5.960464477539063e-08, 0x0001), (1e-8, 0x0000), (100_000, 0x7C00)
        ]
        for (value, bits) in cases {
            XCTAssertEqual(LookResources.halfBits(value), bits, "\(value)")
        }
    }

    // MARK: - CIEDE2000 (Sharma, Wu & Dalal test data)

    func testCIEDE2000AgainstSharmaPairs() {
        typealias Lab = DeltaE.Lab
        let reference = Lab(l: 50, a: 0, b: -82.7485)
        let pairs: [(Lab, Lab, Double)] = [
            (Lab(l: 50, a: 2.6772, b: -79.7751), reference, 2.0425),
            (Lab(l: 50, a: 3.1571, b: -77.2803), reference, 2.8615),
            (Lab(l: 50, a: 2.8361, b: -74.0200), reference, 3.4412),
            (Lab(l: 50, a: 0, b: 0), Lab(l: 50, a: -1, b: 2), 2.3669),
            (Lab(l: 50, a: -0.001, b: 2.49), Lab(l: 50, a: 0.0009, b: -2.49), 4.8045),
            (Lab(l: 50, a: 2.5, b: 0), Lab(l: 73, a: 25, b: -18), 27.1492)
        ]
        for (lhs, rhs, expected) in pairs {
            XCTAssertEqual(DeltaE.ciede2000(lhs, rhs), expected, accuracy: 0.0001)
            XCTAssertEqual(DeltaE.ciede2000(rhs, lhs), expected, accuracy: 0.0001)
        }
        XCTAssertEqual(DeltaE.ciede2000(reference, reference), 0, accuracy: 1e-12)
    }

    func testSRGBToLab() {
        let white = DeltaE.lab(fromSRGB: 1, 1, 1)
        XCTAssertEqual(white.l, 100, accuracy: 0.01)
        XCTAssertEqual(white.a, 0, accuracy: 0.01)
        XCTAssertEqual(white.b, 0, accuracy: 0.01)
        let grey = DeltaE.lab(fromSRGB: 0.5, 0.5, 0.5)
        XCTAssertEqual(grey.l, 53.39, accuracy: 0.05)
    }

    // MARK: - Themes (§4)

    func testEachValueAppearsInOnePlace() {
        // Pro: values on the Fn tiles, a status header above. Edition: values large in the strip,
        // names only on the tiles.
        XCTAssertTrue(CameraTheme.alpha.tilesShowValues)
        XCTAssertEqual(CameraTheme.alpha.telemetry, .dense)
        XCTAssertFalse(CameraTheme.edition.tilesShowValues)
        XCTAssertEqual(CameraTheme.edition.telemetry, .minimal)
    }

    func testEditionTheme() {
        let theme = CameraTheme.edition
        XCTAssertEqual(theme.id, .edition)
        XCTAssertTrue(theme.emphasisByInversion)
        XCTAssertEqual(theme.tiles, [.mode, .aperture, .shutter, .iso, .ev])
        XCTAssertEqual(theme.dial, .rotary)
        XCTAssertEqual(theme.shutter, .flatDisc)
        XCTAssertEqual(theme.badge, .inverted)
        XCTAssertEqual(CameraTheme.theme(for: .edition).id, .edition)
        XCTAssertEqual(CameraTheme.theme(for: .alpha).id, .alpha)
    }

    func testTrayFitsItsTallestContent() {
        // Focus tray: 30 (mode) + 4 + 28 (wheel) + 4 + 12 (distance bar), inside 6 pt padding.
        for theme in [CameraTheme.alpha, CameraTheme.edition] {
            XCTAssertGreaterThanOrEqual(theme.trayHeight - 12, 30 + 4 + 28 + 4 + 12)
        }
    }

    // MARK: - Settings

    func testEditionSettingsPersist() throws {
        var profile = ShootingProfile()
        profile.theme = .edition
        profile.framing = .xpan
        profile.grain = .medium
        profile.shutterSound = .off
        profile.previewGrain = true
        let decoded = try JSONDecoder().decode(ShootingProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.theme, .edition)
        XCTAssertEqual(decoded.framing, .xpan)
        XCTAssertEqual(decoded.grain, .medium)
        XCTAssertEqual(decoded.shutterSound, .off)
        XCTAssertTrue(decoded.previewGrain)
    }

    func testOlderProfilesGetEditionDefaults() throws {
        let decoded = try JSONDecoder().decode(ShootingProfile.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.theme, .alpha)
        XCTAssertEqual(decoded.framing, .native)
        XCTAssertEqual(decoded.grain, .fine)
        XCTAssertEqual(decoded.shutterSound, .low)
        XCTAssertFalse(decoded.previewGrain)
    }

    func testShutterSoundGain() {
        XCTAssertEqual(ShutterSoundVolume.off.gain, 0)
        XCTAssertLessThan(ShutterSoundVolume.low.gain, ShutterSoundVolume.medium.gain)
        XCTAssertLessThanOrEqual(ShutterSoundVolume.medium.gain, 1)
    }

    func testEditionOutputMetadata() {
        let source: [String: Any] = [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyPixelWidth as String: 8064,
            kCGImagePropertyPixelHeight as String: 6048,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifISOSpeedRatings as String: [200],
                kCGImagePropertyExifPixelXDimension as String: 8064
            ]
        ]
        let output = EditionDeveloper.outputProperties(from: source)
        XCTAssertEqual(output[kCGImagePropertyOrientation as String] as? Int, 1)
        XCTAssertNil(output[kCGImagePropertyPixelWidth as String])
        let tiff = output[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFSoftware as String] as? String, Branding.editionSoftwareTag)
        let exif = output[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNotNil(exif?[kCGImagePropertyExifISOSpeedRatings as String])
        XCTAssertNil(exif?[kCGImagePropertyExifPixelXDimension as String])
    }
}
