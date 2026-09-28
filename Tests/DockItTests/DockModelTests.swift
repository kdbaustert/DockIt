import XCTest
@testable import DockIt

final class DockModelTests: XCTestCase {
    private let safari = "/Applications/Safari.app"
    private let mail = "/System/Applications/Mail.app"
    private let notes = "/System/Applications/Notes.app"
    private let spacer = spacerPrefix + "A"

    private func app(_ path: String, pinned: Bool = true) -> DockItem {
        DockItem(
            id: DockModel.key(URL(fileURLWithPath: path)), kind: .app, url: URL(fileURLWithPath: path),
            name: "", isPinned: pinned, isRunning: false, pid: nil)
    }

    private var finder: DockItem { app(DockModel.finderPath) }

    // MARK: - placed

    func testNewAppWithNoTargetGoesLast() {
        XCTAssertEqual(DockModel.placed(notes, before: nil, in: [safari, mail]), [safari, mail, notes])
    }

    func testMovingAnAppTakesItOutOfItsOldPlace() {
        XCTAssertEqual(DockModel.placed(mail, before: app(safari), in: [safari, notes, mail]), [mail, safari, notes])
    }

    /// Finder is always first on the bar but never in the list, so "before Finder" is the list's start.
    func testDropBeforeFinderGoesFirst() {
        XCTAssertEqual(DockModel.placed(notes, before: finder, in: [safari, mail]), [notes, safari, mail])
    }

    func testDropOntoItselfChangesNothing() {
        XCTAssertNil(DockModel.placed(safari, before: app(safari), in: [safari, mail]))
    }

    func testFinderIsNeverPinned() {
        XCTAssertNil(DockModel.placed(DockModel.finderPath, before: nil, in: [safari]))
    }

    func testOnlyAppsAndSpacersArePinned() {
        XCTAssertNil(DockModel.placed("/Users/me/Downloads", before: nil, in: [safari]))
    }

    func testSpacerMovesLikeAnApp() {
        let target = DockItem(id: spacer, kind: .spacer, url: nil, name: "", isPinned: true, isRunning: false, pid: nil)
        XCTAssertEqual(DockModel.placed(notes, before: target, in: [safari, spacer, mail]), [safari, notes, spacer, mail])
        XCTAssertEqual(DockModel.placed(spacer, before: app(safari), in: [safari, spacer, mail]), [spacer, safari, mail])
    }

    /// A running-but-unpinned icon or a stack has no slot in the pinned list to land before.
    func testUnpinnedOrNonAppTargetAppends() {
        XCTAssertEqual(DockModel.placed(notes, before: app(mail, pinned: false), in: [safari]), [safari, notes])
        let stack = DockItem(
            id: "folder:/tmp", kind: .folder, url: URL(fileURLWithPath: "/tmp"), name: "", isPinned: true,
            isRunning: false, pid: nil)
        XCTAssertEqual(DockModel.placed(notes, before: stack, in: [safari]), [safari, notes])
    }

    /// The pinned path and the path it is moved by can name one app two ways.
    func testMatchesPinnedAppsByResolvedPath() {
        let alias = "/Applications/./Safari.app"
        XCTAssertEqual(DockModel.placed(alias, before: nil, in: [safari, mail]), [mail, alias])
    }

    // MARK: - badges

    func testBadgesKeyedByItemID() {
        let badges = DockModel.badges(from: [
            (URL(fileURLWithPath: mail), "3"),
            (URL(fileURLWithPath: safari), nil),
            (URL(fileURLWithPath: notes), ""),
            // The Trash and minimized windows carry no URL.
            (nil, "1"),
            (URL(string: "https://example.com"), "9"),
        ])
        XCTAssertEqual(badges, [app(mail).id: "3"])
    }
}
