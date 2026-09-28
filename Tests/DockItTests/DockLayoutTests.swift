import XCTest
@testable import DockIt

final class DockLayoutTests: XCTestCase {
    // No spacing, so an icon's segment is exactly its size and positions are easy to state.
    private let metrics = DockMetrics(iconSize: 40, magnifiedSize: 80, spacing: 0, padding: 5, separatorExtent: 10)

    func testRestingRowIsCentred() {
        let layout = DockLayout(magnifies: [true, true, false, true], metrics: metrics, stripLength: 1000, pointer: nil) { _, _ in 1 }
        XCTAssertEqual(layout.sizes, [40, 40, 10, 40])
        XCTAssertEqual(layout.length, 140)
        XCTAssertEqual(layout.start, 430)
    }

    func testZeroFalloffLeavesRowAtRest() {
        let layout = DockLayout(magnifies: [true, true, true], metrics: metrics, stripLength: 1000, pointer: 500) { _, _ in 0 }
        XCTAssertEqual(layout.sizes, [40, 40, 40])
        XCTAssertEqual(layout.start, 435)
    }

    func testSeparatorsNeverGrow() {
        let layout = DockLayout(magnifies: [true, false, true], metrics: metrics, stripLength: 1000, pointer: 500) { _, _ in 1 }
        XCTAssertEqual(layout.sizes, [80, 10, 80])
    }

    func testPointStaysUnderPointer() {
        // At rest the row starts at 435 and the second icon at 435 + 5 + 40 = 480. Fully magnified,
        // the second icon must still start under a pointer at 480: start = 480 - (5 + 80).
        let layout = DockLayout(magnifies: [true, true, true], metrics: metrics, stripLength: 1000, pointer: 480) { _, _ in 1 }
        XCTAssertEqual(layout.length, 250)
        XCTAssertEqual(layout.start, 395)
        XCTAssertEqual(layout.index(at: 480), 1)
    }

    func testGrownRowIsClampedToStrip() {
        // Resting row 65...195; the pointer is 35 points into the last icon. Anchoring it there puts
        // the grown row's start at 185 - (5 + 160 + 70) = -50, past the strip's end, so it clamps.
        let layout = DockLayout(magnifies: [true, true, true], metrics: metrics, stripLength: 260, pointer: 185) { _, _ in 1 }
        XCTAssertEqual(layout.start, 0)
    }

    func testPointerPastRowEndKeepsEndAnchored() {
        // Resting row 435...565. A pointer at its very end anchors the grown row at 565 - 250 = 315;
        // past the end the row must stay there, not jump to the centred 375.
        let atEnd = DockLayout(magnifies: [true, true, true], metrics: metrics, stripLength: 1000, pointer: 564.99) { _, _ in 1 }
        let beyond = DockLayout(magnifies: [true, true, true], metrics: metrics, stripLength: 1000, pointer: 600) { _, _ in 1 }
        XCTAssertEqual(atEnd.start, 315, accuracy: 0.01)
        XCTAssertEqual(beyond.start, atEnd.start, accuracy: 0.01)
    }

    func testCenterMatchesIndex() {
        // Resting row starts at 430 (see testRestingRowIsCentred); first icon spans 435...475.
        let layout = DockLayout(magnifies: [true, true, false, true], metrics: metrics, stripLength: 1000, pointer: nil) { _, _ in 1 }
        XCTAssertEqual(layout.center(of: 0), 455)
        XCTAssertEqual(layout.index(at: layout.center(of: 3)), 3)
    }

    func testIndexOutsideRowIsNil() {
        let layout = DockLayout(magnifies: [true], metrics: metrics, stripLength: 1000, pointer: nil) { _, _ in 0 }
        XCTAssertNil(layout.index(at: 0))
        XCTAssertEqual(layout.index(at: 500), 0)
    }
}
