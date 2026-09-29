import XCTest
@testable import DockPlus

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

    // MARK: - Dragging along the bar

    private func item(_ id: String, _ kind: DockItem.Kind, pinned: Bool = true) -> DockItem {
        DockItem(id: id, kind: kind, url: nil, name: "", isPinned: pinned, isRunning: false, pid: nil)
    }

    /// Finder, Safari, Mail, the separator, the Trash and two widgets.
    private var bar: [DockItem] {
        [finder, app(safari), app(mail), item("separator", .separator), item("trash", .trash),
         item("widget:clock", .clock), item("widget:weather", .weather)]
    }

    func testDraggedIconSitsAtItsGapAndLeavesTheBarWithout() {
        let moved = DockModel.arranged(bar, drag: DockDrag(id: app(mail).id, gap: 1))
        XCTAssertEqual(moved.map(\.id), [finder, app(mail), app(safari)].map(\.id) + bar.dropFirst(3).map(\.id))
        let lifted = DockModel.arranged(bar, drag: DockDrag(id: app(mail).id, gap: nil))
        XCTAssertFalse(lifted.contains { $0.id == app(mail).id })
        XCTAssertEqual(lifted.count, bar.count - 1)
    }

    /// Before Finder is allowed; over the Trash the gap waits at the separator.
    func testAppGapStaysBeforeTheSeparator() {
        XCTAssertEqual(DockModel.gap(for: app(mail), over: 0, in: bar), 0)
        XCTAssertEqual(DockModel.gap(for: app(mail), over: 1, in: bar), 1)
        XCTAssertEqual(DockModel.gap(for: app(mail), over: 4, in: bar), 2)
        XCTAssertNil(DockModel.gap(for: app(mail), over: nil, in: bar))
    }

    /// A running app that is not pinned is no wall: an app can go after it.
    func testAppGapPassesARunningApp() {
        let teams = item("/Applications/Teams.app", .app, pinned: false)
        let shown = [finder, app(safari), app(mail), teams, item("separator", .separator), item("trash", .trash)]
        XCTAssertEqual(DockModel.gap(for: app(safari), over: 3, in: shown), 3)
    }

    /// Dropped after a running app, the running apps keep their places: each follows the pinned
    /// item before it, the dropped app counting as pinned.
    func testDropRecordsWhereRunningAppsStand() {
        let teams = item("teams", .app, pinned: false)
        let zoom = item("zoom", .app, pinned: false)
        let shown = [zoom, finder, app(mail), teams, app(safari), item("separator", .separator), item("trash", .trash)]
        XCTAssertEqual(DockModel.anchors(in: shown, pinning: app(safari).id), ["zoom": "", "teams": app(mail).id])
    }

    func testWidgetGapStaysAmongTheWidgets() {
        let clock = item("widget:clock", .clock)
        XCTAssertEqual(DockModel.gap(for: clock, over: 1, in: bar), 5)
        XCTAssertEqual(DockModel.gap(for: clock, over: 6, in: bar), 6)
    }

    func testFinderDragsButTheTrashAndStacksDoNot() {
        XCTAssertEqual(DockModel.gapRange(for: finder, in: Array(bar.dropFirst())), 0...2)
        XCTAssertNil(DockModel.gapRange(for: item("trash", .trash), in: bar))
        XCTAssertNil(DockModel.gapRange(for: item("folder:/a", .folder), in: bar))
    }

    // MARK: - placed

    func testNewAppWithNoTargetGoesLast() {
        XCTAssertEqual(DockModel.placed(notes, before: nil, in: [safari, mail]), [safari, mail, notes])
    }

    func testMovingAnAppTakesItOutOfItsOldPlace() {
        XCTAssertEqual(DockModel.placed(mail, before: app(safari), in: [safari, notes, mail]), [mail, safari, notes])
    }

    /// Finder is first but not in the list until moved, so going before it writes it in after.
    func testDropBeforeFinderWritesFinderIn() {
        XCTAssertEqual(
            DockModel.placed(notes, before: finder, in: [safari, mail]), [notes, DockModel.finderPath, safari, mail])
    }

    func testDropOntoItselfChangesNothing() {
        XCTAssertNil(DockModel.placed(safari, before: app(safari), in: [safari, mail]))
    }

    func testMovedFinderIsWrittenIntoTheList() {
        XCTAssertEqual(DockModel.placed(DockModel.finderPath, before: nil, in: [safari]), [safari, DockModel.finderPath])
    }

    /// Moved back to first place, Finder leaves the list again, so the list is the one it always was.
    func testFinderMovedBackFirstLeavesTheList() {
        XCTAssertEqual(DockModel.placed(DockModel.finderPath, before: app(safari), in: [safari, DockModel.finderPath]),
                       [safari])
        XCTAssertNil(DockModel.placed(DockModel.finderPath, before: app(safari), in: [safari]))
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

    // MARK: - reordered (widgets)

    func testWidgetMovesBeforeTarget() {
        XCTAssertEqual(
            DockModel.reordered(["nowPlaying", "weather", "clock"], moving: "clock", before: "nowPlaying"),
            ["clock", "nowPlaying", "weather"])
    }

    func testWidgetWithNoTargetGoesLast() {
        XCTAssertEqual(
            DockModel.reordered(["nowPlaying", "weather", "clock"], moving: "nowPlaying", before: nil),
            ["weather", "clock", "nowPlaying"])
    }

    /// A target that is not in the order — a stale drag — puts the widget last rather than losing it.
    func testWidgetWithUnknownTargetGoesLast() {
        XCTAssertEqual(
            DockModel.reordered(["weather", "clock"], moving: "weather", before: "gone"), ["clock", "weather"])
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
