import CoreGraphics
import XCTest
@testable import ManualCameraApp

final class GeometryAndPolicyTests: XCTestCase {

    func testAspectFitPortraitImageOnTallScreen() {
        let rect = ViewfinderGeometry.aspectFit(aspectRatio: 3.0 / 4.0, in: CGRect(x: 0, y: 0, width: 390, height: 844))
        XCTAssertEqual(rect, CGRect(x: 0, y: 162, width: 390, height: 520))
    }

    func testAspectFitLandscapeImageInSquare() {
        let rect = ViewfinderGeometry.aspectFit(aspectRatio: 4.0 / 3.0, in: CGRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertEqual(rect.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 37.5, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 300, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 225, accuracy: 1e-9)
    }

    func testNormalizedPointAndClamping() {
        let geometry = ViewfinderGeometry(
            bounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            videoRect: CGRect(x: 0, y: 162, width: 390, height: 520)
        )
        XCTAssertEqual(geometry.normalizedPoint(for: CGPoint(x: 195, y: 422)), CGPoint(x: 0.5, y: 0.5))
        XCTAssertNil(geometry.normalizedPoint(for: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(geometry.clampedToVideo(CGPoint(x: 10, y: 10)), CGPoint(x: 10, y: 162))
    }

    func testStoragePolicy() {
        XCTAssertEqual(StoragePolicy.level(forAvailableBytes: nil), .ok)
        XCTAssertEqual(StoragePolicy.level(forAvailableBytes: 100_000_000), .critical)
        XCTAssertEqual(StoragePolicy.level(forAvailableBytes: 150_000_000), .low)
        XCTAssertEqual(StoragePolicy.level(forAvailableBytes: 300_000_000), .low)
        XCTAssertEqual(StoragePolicy.level(forAvailableBytes: 500_000_000), .ok)
        XCTAssertEqual(StoragePolicy.level(forAvailableBytes: 2_000_000_000), .ok)
    }

    func testHistogramNormalisation() {
        var counts = [UInt32](repeating: 0, count: 1024)
        counts[10] = 50
        counts[11] = 25
        counts[256 + 128] = 7
        counts[768] = 2
        counts[1023] = 5
        let sample = FramePipeline.normalise(counts: counts, samples: 100)
        XCTAssertEqual(sample.red[10], 1)
        XCTAssertEqual(sample.red[11], 0.5)
        XCTAssertEqual(sample.red[0], 0)
        XCTAssertEqual(sample.green[128], 1)
        XCTAssertEqual(sample.blue.max(), 0, "An empty channel stays at zero")
        XCTAssertEqual(sample.shadowClip, 0.02, accuracy: 1e-6)
        XCTAssertEqual(sample.highlightClip, 0.05, accuracy: 1e-6)
        XCTAssertEqual(FramePipeline.normalise(counts: [1, 2], samples: 1), .empty)
    }

    func testHistogramDifference() {
        var counts = [UInt32](repeating: 1, count: 1024)
        let a = FramePipeline.normalise(counts: counts, samples: 10)
        counts[5] = 2
        let b = FramePipeline.normalise(counts: counts, samples: 10)
        XCTAssertEqual(a.maxDifference(to: a), 0)
        XCTAssertGreaterThan(a.maxDifference(to: b), 0.01)
        XCTAssertEqual(a.maxDifference(to: .empty), .infinity)
    }

    func testLiveValuesChangeThreshold() {
        let base = LiveDeviceValues(iso: 100, shutter: 0.01, lensPosition: 0.5, temperature: 5000, aperture: 1.8, meterOffset: 0, isAdjustingFocus: false)
        var tiny = base
        tiny.iso = 100.4
        XCTAssertFalse(tiny.differsNoticeably(from: base))
        var bigger = base
        bigger.shutter = 0.012
        XCTAssertTrue(bigger.differsNoticeably(from: base))
        XCTAssertTrue(base.differsNoticeably(from: nil))
    }
}
