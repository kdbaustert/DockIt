import XCTest
@testable import DockPlus

final class RunningAppsTileTests: XCTestCase {
    /// The tile counts its slots back out of the width `DockItem.runningAppsWidth` gave it, so the two
    /// must agree, or the last icon turns into a "+N" it had room for. Heights are the bar's icon
    /// sizes: 16 is the floor a crowded bar shrinks to, 24 and 128 the size slider's ends, and 48 the
    /// default and the settings gallery's.
    func testSlotsInvertTheWidthTheTileWasGiven() {
        for height: CGFloat in [16, 24, 48, 128] {
            for count in [0, 1, 8, 9, 30] {
                let width = DockItem.runningAppsWidth(count: count, height: height)
                let slots = RunningAppsTile.slots(
                    width: width, inset: DockItem.runningAppsInset, gap: DockItem.runningAppsGap,
                    size: DockItem.runningAppsIconSize(height: height))
                XCTAssertEqual(
                    slots, min(max(count, 1), DockItem.runningAppsShown), "\(count) apps at height \(height)")
            }
        }
    }
}
