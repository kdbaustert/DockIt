import CoreGraphics
import XCTest
@testable import DockPlus

/// "Show only this display's windows in previews": which windows belong to which display. Window-
/// server coordinates, with a second 1920×1080 display to the right of a 1440×900 one.
final class PreviewDisplayFilterTests: XCTestCase {
    private let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    func testWindowWhollyOnOneDisplay() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertTrue(PreviewController.isMostlyOn(window, display: left))
        XCTAssertFalse(PreviewController.isMostlyOn(window, display: right))
    }

    /// Straddling the seam, it belongs to the display holding most of it — and only that one.
    func testStraddlingWindowGoesToTheLargerShare() {
        let window = CGRect(x: 1240, y: 100, width: 800, height: 600)  // 200 left, 600 right
        XCTAssertFalse(PreviewController.isMostlyOn(window, display: left))
        XCTAssertTrue(PreviewController.isMostlyOn(window, display: right))
    }

    /// Exactly half is not "mostly": an even split shows on neither dock rather than on both.
    func testEvenSplitIsOnNeither() {
        let window = CGRect(x: 1040, y: 100, width: 800, height: 600)
        XCTAssertFalse(PreviewController.isMostlyOn(window, display: left))
        XCTAssertFalse(PreviewController.isMostlyOn(window, display: right))
    }

    /// Partly off the top of the screen still counts by the part that is on it.
    func testPartlyOffScreenStillCounts() {
        let window = CGRect(x: 100, y: -200, width: 800, height: 600)
        XCTAssertTrue(PreviewController.isMostlyOn(window, display: left))
    }

    func testEmptyFrameIsOnNothing() {
        XCTAssertFalse(PreviewController.isMostlyOn(.zero, display: left))
        XCTAssertFalse(PreviewController.isMostlyOn(.null, display: left))
    }
}
