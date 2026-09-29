import XCTest
@testable import DockPlus

final class MagnificationTests: XCTestCase {
    func testFullGrowthUnderPointer() {
        XCTAssertEqual(magnificationFalloff(distance: 0, iconSize: 48), 1, accuracy: 1e-9)
    }

    func testNoGrowthAtAndPastReach() {
        // Default reach is two icon widths: 96 points at 48-point icons.
        XCTAssertEqual(magnificationFalloff(distance: 96, iconSize: 48), 0)
        XCTAssertEqual(magnificationFalloff(distance: 500, iconSize: 48), 0)
    }

    func testGrowthFallsMonotonically() {
        var previous = magnificationFalloff(distance: 0, iconSize: 48)
        for distance in stride(from: 1.0, through: 96, by: 1) {
            let value = magnificationFalloff(distance: distance, iconSize: 48)
            XCTAssertLessThanOrEqual(value, previous, "rose at \(distance)")
            previous = value
        }
    }

    func testReachScalesCutoff() {
        // 120 points is past a two-icon reach but inside a four-icon one.
        XCTAssertEqual(magnificationFalloff(distance: 120, iconSize: 48, reachIcons: 2), 0)
        XCTAssertGreaterThan(magnificationFalloff(distance: 120, iconSize: 48, reachIcons: 4), 0)
        XCTAssertEqual(magnificationFalloff(distance: 192, iconSize: 48, reachIcons: 4), 0)
    }
}
