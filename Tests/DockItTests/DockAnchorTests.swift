import XCTest
@testable import DockIt

/// Where the previews and a stack's grid hang off the bar.
final class DockAnchorTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = NSSize(width: 200, height: 100)

    func testBottomCentresOnTheItemClearOfTheBar() {
        let dock = NSRect(x: 0, y: 0, width: 1000, height: 120)
        let anchor = DockAnchor(center: 500, dockFrame: dock, edge: .bottom, barReach: 60)
        XCTAssertEqual(anchor.frame(for: size, within: screen), NSRect(x: 400, y: 64, width: 200, height: 100))
    }

    /// Along-axis positions run down from the strip's top on a side dock.
    func testSidesHangOutwardFromTheEdge() {
        let left = NSRect(x: 0, y: 0, width: 300, height: 800)
        let fromLeft = DockAnchor(center: 200, dockFrame: left, edge: .left, barReach: 60)
        XCTAssertEqual(fromLeft.frame(for: size, within: screen), NSRect(x: 64, y: 550, width: 200, height: 100))
        let right = NSRect(x: 700, y: 0, width: 300, height: 800)
        let fromRight = DockAnchor(center: 200, dockFrame: right, edge: .right, barReach: 60)
        XCTAssertEqual(fromRight.frame(for: size, within: screen), NSRect(x: 736, y: 550, width: 200, height: 100))
    }

    /// An item near a corner keeps the panel 8pt inside the screen rather than spilling off it.
    func testClampsInsideTheVisibleFrame() {
        let dock = NSRect(x: 0, y: 0, width: 1000, height: 120)
        let nearLeft = DockAnchor(center: 20, dockFrame: dock, edge: .bottom, barReach: 60)
        XCTAssertEqual(nearLeft.frame(for: size, within: screen).minX, 8)
        let nearRight = DockAnchor(center: 990, dockFrame: dock, edge: .bottom, barReach: 60)
        XCTAssertEqual(nearRight.frame(for: size, within: screen).maxX, 992)
    }

    /// With no screen to clamp to, the panel goes exactly where the anchor puts it.
    func testUnclampedWithoutAScreen() {
        let dock = NSRect(x: 0, y: 0, width: 1000, height: 120)
        let anchor = DockAnchor(center: 20, dockFrame: dock, edge: .bottom, barReach: 60)
        XCTAssertEqual(anchor.frame(for: size, within: nil).minX, -80)
    }
}
