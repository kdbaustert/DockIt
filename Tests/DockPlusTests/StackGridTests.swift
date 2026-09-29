import XCTest
@testable import DockPlus

final class StackGridTests: XCTestCase {
    // MARK: - Display stored per stack

    func testDisplayIsPerStackAndDefaultsToMenu() {
        let displays = StackDisplay.storing(.grid, for: "/a", in: [:], stacks: ["/a", "/b"])
        XCTAssertEqual(StackDisplay.of("/a", in: displays), .grid)
        XCTAssertEqual(StackDisplay.of("/b", in: displays), .menu)
    }

    /// The default is not stored, so an untouched stack adds nothing to the settings file.
    func testMenuIsNotStored() {
        XCTAssertEqual(StackDisplay.storing(.menu, for: "/a", in: ["/a": "grid"], stacks: ["/a"]), [:])
    }

    /// A removed stack's leftover goes on the next write, as with the sorts.
    func testStoringDropsRemovedStacks() {
        let displays = StackDisplay.storing(.grid, for: "/a", in: ["/gone": "grid"], stacks: ["/a"])
        XCTAssertEqual(displays, ["/a": "grid"])
    }

    /// A value a newer DockPlus wrote, or a hand-edited file, reads as the menu rather than failing.
    func testUnknownDisplayReadsAsMenu() {
        XCTAssertEqual(StackDisplay.of("/a", in: ["/a": "fan"]), .menu)
    }

    /// The two maps are kept apart: a sort's raw value is never read as a display, or the reverse.
    func testSortAndDisplayMapsAreIndependent() {
        let sorts = StackSort.storing(.name, for: "/a", in: [:], stacks: ["/a"])
        XCTAssertEqual(StackDisplay.of("/a", in: sorts), .menu)
        let displays = StackDisplay.storing(.grid, for: "/a", in: [:], stacks: ["/a"])
        XCTAssertEqual(StackSort.of("/a", in: displays), .dateAdded)
    }

    /// An older settings file has no displays at all; one written now carries them.
    func testSettingsFilesCarryDisplays() throws {
        let old = try PortableSettings.decoded(from: Data(#"{"stacks": ["/a"], "stackSorts": {"/a": "kind"}}"#.utf8))
        XCTAssertNil(old.stackDisplays)
        XCTAssertEqual(old.stackSorts, ["/a": "kind"])
        let current = PortableSettings(stacks: ["/a"], stackDisplays: ["/a": "grid"])
        XCTAssertEqual(try PortableSettings.decoded(from: current.encoded()), current)
    }

    // MARK: - Grid shape

    func testColumnsAreRoughlySquareAndCapped() {
        XCTAssertEqual(StackGridController.columns(for: 0), 1)
        XCTAssertEqual(StackGridController.columns(for: 1), 1)
        XCTAssertEqual(StackGridController.columns(for: 2), 2)
        XCTAssertEqual(StackGridController.columns(for: 9), 3)
        XCTAssertEqual(StackGridController.columns(for: 10), 4)
        XCTAssertEqual(StackGridController.columns(for: 20), 5)
        XCTAssertEqual(StackGridController.columns(for: 30), 6)
        XCTAssertEqual(StackGridController.columns(for: 500), 6)
    }

    /// The grid's larger cap fills six by five exactly.
    func testGridCapFillsWholeRows() {
        let entries = (0..<50).map {
            StackEntry(
                url: URL(fileURLWithPath: "/stack/\($0)"), name: "\($0)", added: nil, modified: nil, kind: "",
                isFolder: false)
        }
        let shown = DockModel.stackContents(entries, sortedBy: .name, limit: DockModel.stackGridLimit)
        XCTAssertEqual(shown.count, 30)
        XCTAssertEqual(shown.count % StackGridController.columns(for: shown.count), 0)
    }
}
