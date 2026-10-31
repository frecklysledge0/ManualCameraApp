import XCTest
@testable import ManualCameraApp

/// Full aperture control: every 1/3 stop across the iris's range, not only the recommended stops.
final class ApertureTableTests: XCTestCase {

    func testThirdStopsAcrossTheVariableAperture() {
        let table = ExposureMath.apertureTable(min: 1.48, max: 4.0, recommended: [1.48, 1.8, 2.8, 4.0])
        XCTAssertEqual(table, [1.48, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0])
    }

    func testRecommendedStopWinsOverANearbyStandardStop() {
        let table = ExposureMath.apertureTable(min: 1.78, max: 4.0, recommended: [1.78, 2.8, 4.0])
        XCTAssertEqual(table.first, 1.78)
        XCTAssertFalse(table.contains(1.8))
        XCTAssertEqual(table, [1.78, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0])
    }

    func testTableIsAscendingWithoutNearDuplicates() {
        let table = ExposureMath.apertureTable(min: 1.4, max: 16, recommended: [1.4, 2.0, 2.8, 4.0, 5.6, 8, 11, 16])
        for (lhs, rhs) in zip(table, table.dropFirst()) {
            XCTAssertGreaterThan(rhs / lhs, 1.03)
        }
        XCTAssertEqual(table.first, 1.4)
        XCTAssertEqual(table.last, 16)
    }

    func testFixedApertureGivesOneStop() {
        XCTAssertEqual(ExposureMath.apertureTable(min: 1.78, max: 1.78, recommended: []), [1.78])
        XCTAssertEqual(ExposureMath.apertureTable(min: 0, max: 4, recommended: []), [])
    }

    func testFullStops() {
        XCTAssertTrue(ExposureMath.isFullStop(aperture: 2.0))
        XCTAssertTrue(ExposureMath.isFullStop(aperture: 2.8))
        XCTAssertTrue(ExposureMath.isFullStop(aperture: 4.0))
        XCTAssertFalse(ExposureMath.isFullStop(aperture: 2.2))
        XCTAssertFalse(ExposureMath.isFullStop(aperture: 1.48))
    }
}
