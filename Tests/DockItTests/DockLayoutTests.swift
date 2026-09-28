import XCTest
@testable import DockIt

final class DockLayoutTests: XCTestCase {
    // No spacing, so an icon's segment is exactly its size and positions are easy to state.
    private let metrics = DockMetrics(iconSize: 40, magnifiedSize: 80, spacing: 0, padding: 5, separatorExtent: 10)

    /// The shape the tests were written in: true is an icon, false a separator-width fixed item.
    private func specs(_ magnifies: [Bool]) -> [DockItemSpec] {
        magnifies.map { $0 ? .icon(metrics) : .fixed(metrics.separatorExtent) }
    }

    func testRestingRowIsCentred() {
        let layout = DockLayout(items: specs([true, true, false, true]), metrics: metrics, stripLength: 1000, pointer: nil) { _, _ in 1 }
        XCTAssertEqual(layout.sizes, [40, 40, 10, 40])
        XCTAssertEqual(layout.length, 140)
        XCTAssertEqual(layout.start, 430)
    }

    func testZeroFalloffLeavesRowAtRest() {
        let layout = DockLayout(items: specs([true, true, true]), metrics: metrics, stripLength: 1000, pointer: 500) { _, _ in 0 }
        XCTAssertEqual(layout.sizes, [40, 40, 40])
        XCTAssertEqual(layout.start, 435)
    }

    func testSeparatorsNeverGrow() {
        let layout = DockLayout(items: specs([true, false, true]), metrics: metrics, stripLength: 1000, pointer: 500) { _, _ in 1 }
        XCTAssertEqual(layout.sizes, [80, 10, 80])
    }

    func testPointStaysUnderPointer() {
        // At rest the row starts at 435 and the second icon at 435 + 5 + 40 = 480. Fully magnified,
        // the second icon must still start under a pointer at 480: start = 480 - (5 + 80).
        let layout = DockLayout(items: specs([true, true, true]), metrics: metrics, stripLength: 1000, pointer: 480) { _, _ in 1 }
        XCTAssertEqual(layout.length, 250)
        XCTAssertEqual(layout.start, 395)
        XCTAssertEqual(layout.index(at: 480), 1)
    }

    func testGrownRowIsClampedToStrip() {
        // Resting row 65...195; the pointer is 35 points into the last icon. Anchoring it there puts
        // the grown row's start at 185 - (5 + 160 + 70) = -50, past the strip's end, so it clamps.
        let layout = DockLayout(items: specs([true, true, true]), metrics: metrics, stripLength: 260, pointer: 185) { _, _ in 1 }
        XCTAssertEqual(layout.start, 0)
    }

    func testPointerPastRowEndKeepsEndAnchored() {
        // Resting row 435...565. A pointer at its very end anchors the grown row at 565 - 250 = 315;
        // past the end the row must stay there, not jump to the centred 375.
        let atEnd = DockLayout(items: specs([true, true, true]), metrics: metrics, stripLength: 1000, pointer: 564.99) { _, _ in 1 }
        let beyond = DockLayout(items: specs([true, true, true]), metrics: metrics, stripLength: 1000, pointer: 600) { _, _ in 1 }
        XCTAssertEqual(atEnd.start, 315, accuracy: 0.01)
        XCTAssertEqual(beyond.start, atEnd.start, accuracy: 0.01)
    }

    func testCenterMatchesIndex() {
        // Resting row starts at 430 (see testRestingRowIsCentred); first icon spans 435...475.
        let layout = DockLayout(items: specs([true, true, false, true]), metrics: metrics, stripLength: 1000, pointer: nil) { _, _ in 1 }
        XCTAssertEqual(layout.center(of: 0), 455)
        XCTAssertEqual(layout.index(at: layout.center(of: 3)), 3)
    }

    func testWidgetReorder() {
        let order = ["nowPlaying", "weather", "clock"]
        XCTAssertEqual(DockModel.reordered(order, moving: "clock", before: "nowPlaying"),
                       ["clock", "nowPlaying", "weather"])
        XCTAssertEqual(DockModel.reordered(order, moving: "nowPlaying", before: nil),
                       ["weather", "clock", "nowPlaying"])
        // A target that is not in the list appends rather than losing the item.
        XCTAssertEqual(DockModel.reordered(order, moving: "weather", before: "gone"),
                       ["nowPlaying", "clock", "weather"])
    }

    func testWidgetOrderDropsDuplicatesKeepingFirst() {
        XCTAssertEqual(normalizedWidgetOrder(["clock", "weather", "clock", "nowPlaying", "weather"]),
                       ["clock", "weather", "nowPlaying"])
    }

    // An order saved before a widget existed must still show that widget when it is turned on.
    func testWidgetOrderAppendsMissingInDefaultOrder() {
        XCTAssertEqual(normalizedWidgetOrder(["weather"]), ["weather", "nowPlaying", "clock"])
        XCTAssertEqual(normalizedWidgetOrder([]), ["nowPlaying", "weather", "clock"])
    }

    func testWidgetOrderDropsUnknownNames() {
        XCTAssertEqual(normalizedWidgetOrder(["battery", "clock", "", "nowPlaying"]),
                       ["clock", "nowPlaying", "weather"])
    }

    func testIndexOutsideRowIsNil() {
        let layout = DockLayout(items: specs([true]), metrics: metrics, stripLength: 1000, pointer: nil) { _, _ in 0 }
        XCTAssertNil(layout.index(at: 0))
        XCTAssertEqual(layout.index(at: 500), 0)
    }

    // A widget tile is far wider than it is tall; its width must not count as the bar's depth.
    func testWideWidgetDoesNotSetDepth() {
        let items: [DockItemSpec] = [.icon(metrics), .fixed(180)]
        let resting = DockLayout(items: items, metrics: metrics, stripLength: 1000, pointer: nil) { _, _ in 0 }
        XCTAssertEqual(resting.depth, 40)
        let hovered = DockLayout(items: items, metrics: metrics, stripLength: 1000, pointer: 500) { _, _ in 0 }
        XCTAssertEqual(hovered.depth, 40)
    }

    func testDepthFollowsTheTallestMagnifiedIcon() {
        let items: [DockItemSpec] = [.icon(metrics), .fixed(180), .icon(metrics)]
        let layout = DockLayout(items: items, metrics: metrics, stripLength: 1000, pointer: 500) { _, _ in 0.5 }
        XCTAssertEqual(layout.depth, 60)
    }
}
