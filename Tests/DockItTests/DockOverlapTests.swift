import CoreGraphics
import XCTest
@testable import DockIt

/// "Only when a window overlaps the dock": which windows count. Window-server coordinates, y down,
/// on a 1440×900 screen with a bottom bar 600 wide and 60 deep.
final class DockOverlapTests: XCTestCase {
    private let bar = CGRect(x: 420, y: 840, width: 600, height: 60)
    private let me: pid_t = 100

    private func window(
        _ bounds: CGRect, pid: Int = 200, layer: Int = 0, alpha: Double = 1
    ) -> [String: Any] {
        [
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
        ]
    }

    private func overlaps(_ windows: [[String: Any]]) -> Bool {
        DockController.windowOverlaps(bar, windows: windows, ownPID: me)
    }

    func testNoWindowsIsNoOverlap() {
        XCTAssertFalse(overlaps([]))
    }

    /// A maximized window reaches the bottom of the screen with the macOS Dock hidden.
    func testWindowReachingIntoTheBarOverlaps() {
        XCTAssertTrue(overlaps([window(CGRect(x: 0, y: 38, width: 1440, height: 862))]))
    }

    func testWindowAboveTheBarDoesNot() {
        XCTAssertFalse(overlaps([window(CGRect(x: 100, y: 100, width: 800, height: 600))]))
    }

    /// Low beside the bar, not over it: overlap is the bar's own extent, not the whole edge.
    func testWindowBesideTheBarDoesNot() {
        XCTAssertFalse(overlaps([window(CGRect(x: 0, y: 700, width: 400, height: 200))]))
    }

    /// Ending exactly where the bar begins shares an edge and no area.
    func testWindowTouchingTheBarDoesNot() {
        XCTAssertFalse(overlaps([window(CGRect(x: 100, y: 100, width: 800, height: 740))]))
    }

    /// Settings, and any other window of DockIt's own, never hides the dock.
    func testOwnWindowsDoNotCount() {
        XCTAssertFalse(overlaps([window(CGRect(x: 400, y: 500, width: 700, height: 400), pid: Int(me))]))
    }

    /// Menu bar (24), status items (25), the Dock (20), popovers and panels above the normal layer.
    func testOtherLayersDoNotCount() {
        for layer in [24, 25, 20, 3, 101] {
            XCTAssertFalse(overlaps([window(bar, layer: layer)]), "layer \(layer)")
        }
    }

    func testTransparentWindowDoesNotCount() {
        XCTAssertFalse(overlaps([window(bar, alpha: 0)]))
    }

    /// Any one qualifying window among ones that do not is enough.
    func testOneQualifyingWindowAmongOthers() {
        XCTAssertTrue(overlaps([
            window(bar, layer: 25),
            window(bar, pid: Int(me)),
            window(CGRect(x: 1000, y: 850, width: 300, height: 50)),
        ]))
    }

    /// Entries the window server describes without the keys are skipped, not trusted.
    func testMalformedEntriesDoNotCount() {
        XCTAssertFalse(overlaps([[kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: 200]]))
    }
}
