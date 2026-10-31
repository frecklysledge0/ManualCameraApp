import XCTest
@testable import ManualCameraApp

/// Zoom-label maths used by `DeviceCatalog` (§8).
final class DeviceCatalogTests: XCTestCase {

    func testTripleCameraWithFiveTimesTelephoto() {
        XCTAssertEqual(LensMath.zoomLabels(switchOverFactors: [2, 10], hasUltraWide: true), [0.5, 1, 5])
    }

    func testTripleCameraWithFourTimesTelephoto() {
        XCTAssertEqual(LensMath.zoomLabels(switchOverFactors: [2, 8], hasUltraWide: true), [0.5, 1, 4])
    }

    func testTripleCameraWithThreeTimesTelephoto() {
        XCTAssertEqual(LensMath.zoomLabels(switchOverFactors: [2, 6], hasUltraWide: true), [0.5, 1, 3])
    }

    func testDualWideCamera() {
        XCTAssertEqual(LensMath.zoomLabels(switchOverFactors: [2], hasUltraWide: true), [0.5, 1])
    }

    func testDualCameraWithoutUltraWide() {
        XCTAssertEqual(LensMath.zoomLabels(switchOverFactors: [2], hasUltraWide: false), [1, 2])
    }

    func testInvalidFactors() {
        XCTAssertEqual(LensMath.zoomLabels(switchOverFactors: [], hasUltraWide: true), [])
        XCTAssertEqual(LensMath.zoomLabels(switchOverFactors: [10, 2], hasUltraWide: true), [])
        XCTAssertEqual(LensMath.zoomLabels(switchOverFactors: [0, -1], hasUltraWide: true), [])
    }

    func testFieldOfViewHeuristic() {
        XCTAssertEqual(LensMath.zoomFromFieldOfView(lensFOV: 15.94, wideFOV: 70), 5)
        XCTAssertEqual(LensMath.zoomFromFieldOfView(lensFOV: 19.86, wideFOV: 70), 4)
        XCTAssertEqual(LensMath.zoomFromFieldOfView(lensFOV: 108.94, wideFOV: 70), 0.5)
        XCTAssertEqual(LensMath.zoomFromFieldOfView(lensFOV: 70, wideFOV: 70), 1)
        XCTAssertEqual(LensMath.zoomFromFieldOfView(lensFOV: 0, wideFOV: 70), 1, "Invalid input falls back to 1×")
    }

    func testButtonText() {
        XCTAssertEqual(LensMath.buttonText(for: 0.5), ".5")
        XCTAssertEqual(LensMath.buttonText(for: 1), "1")
        XCTAssertEqual(LensMath.buttonText(for: 5), "5")
        XCTAssertEqual(LensMath.buttonText(for: 2.5), "2.5")
    }

    func testRoundLabel() {
        XCTAssertEqual(LensMath.roundLabel(4.97), 5)
        XCTAssertEqual(LensMath.roundLabel(0.49), 0.5)
        XCTAssertEqual(LensMath.roundLabel(2.46), 2.5)
    }
}
