import XCTest
@testable import DockPlus

/// Options ▸ Assign To's Desktop items, apart from the window server.
final class DesktopAssignmentsTests: XCTestCase {
    private typealias Option = DesktopAssignments.Option

    private func display(_ current: String?, _ desktops: [String]) -> DesktopAssignments.Display {
        DesktopAssignments.Display(current: current, desktops: desktops)
    }

    func testOneDisplayOffersThisDesktop() {
        XCTAssertEqual(
            DesktopAssignments.desktopOptions(displays: [display("b", ["a", "b"])], current: .none),
            [Option(title: "This Desktop", assignment: .desktop("b"))])
    }

    /// Spotify's menu, as the macOS Dock showed it with two displays: each display's front Desktop,
    /// and the bound one after its own display's.
    func testSeveralDisplaysOfferEachDisplaysDesktopAndTheBoundOne() {
        let displays = [display("a1", ["a1", "a2", "a3", "a4", "a5"]), display("b1", ["b1"])]
        XCTAssertEqual(
            DesktopAssignments.desktopOptions(displays: displays, current: .desktop("a5")),
            [Option(title: "Desktop on Display 1", assignment: .desktop("a1")),
             Option(title: "Desktop 5 on Display 1", assignment: .desktop("a5")),
             Option(title: "Desktop on Display 2", assignment: .desktop("b1"))])
    }

    /// Bound to the Desktop in front: it is ticked there, not listed a second time by number.
    func testBoundToTheFrontDesktopIsNotListedTwice() {
        XCTAssertEqual(
            DesktopAssignments.desktopOptions(displays: [display("b", ["a", "b"])], current: .desktop("b")),
            [Option(title: "This Desktop", assignment: .desktop("b"))])
    }

    func testBoundToAnotherDesktopOnOneDisplayShowsItsNumber() {
        XCTAssertEqual(
            DesktopAssignments.desktopOptions(displays: [display("a", ["a", "b", "c"])], current: .desktop("c")),
            [Option(title: "This Desktop", assignment: .desktop("a")),
             Option(title: "Desktop 3", assignment: .desktop("c"))])
    }

    /// A binding to a Desktop since removed keeps its tick, but cannot be picked again.
    func testBoundToAGoneDesktopShowsAnotherDesktop() {
        XCTAssertEqual(
            DesktopAssignments.desktopOptions(displays: [display("a", ["a"])], current: .desktop("gone")),
            [Option(title: "This Desktop", assignment: .desktop("a")),
             Option(title: "Another Desktop", assignment: .desktop("gone"), isEnabled: false)])
    }

    // MARK: - Where the app's windows are

    /// Its window on Desktop 3 while Desktop 1 is in front: Desktop 3 is offered, not the front one.
    func testOffersTheDesktopTheAppsWindowIsOn() {
        XCTAssertEqual(
            DesktopAssignments.desktopOptions(
                displays: [display("a", ["a", "b", "c"])], current: .none, appDesktops: ["c"]),
            [Option(title: "Desktop 3", assignment: .desktop("c"))])
    }

    /// Its window on the Desktop in front keeps that Desktop's own name.
    func testAWindowOnTheFrontDesktopIsThisDesktop() {
        XCTAssertEqual(
            DesktopAssignments.desktopOptions(
                displays: [display("a", ["a", "b"])], current: .none, appDesktops: ["a"]),
            [Option(title: "This Desktop", assignment: .desktop("a"))])
    }

    /// Windows on two Desktops of one display offer both, in their numbered order; a display with
    /// none of its windows still offers its front Desktop.
    func testWindowsOnSeveralDesktopsOfferEach() {
        let displays = [display("a1", ["a1", "a2", "a3"]), display("b1", ["b1"])]
        XCTAssertEqual(
            DesktopAssignments.desktopOptions(displays: displays, current: .none, appDesktops: ["a3", "a2"]),
            [Option(title: "Desktop 2 on Display 1", assignment: .desktop("a2")),
             Option(title: "Desktop 3 on Display 1", assignment: .desktop("a3")),
             Option(title: "Desktop on Display 2", assignment: .desktop("b1"))])
    }

    /// Bound to the Desktop its window is on: listed once, ticked.
    func testBoundToTheWindowsDesktopIsNotListedTwice() {
        XCTAssertEqual(
            DesktopAssignments.desktopOptions(
                displays: [display("a", ["a", "b"])], current: .desktop("b"), appDesktops: ["b"]),
            [Option(title: "Desktop 2", assignment: .desktop("b"))])
    }

    /// An empty UUID would save as All Desktops, so a Desktop that has one cannot be picked.
    func testADesktopWithNoUUIDIsDisabled() {
        XCTAssertEqual(
            DesktopAssignments.desktopOptions(displays: [display("", ["a", ""])], current: .none),
            [Option(title: "This Desktop", assignment: .desktop(""), isEnabled: false)])
        XCTAssertEqual(
            DesktopAssignments.desktopOptions(displays: [display(nil, [])], current: .none),
            [Option(title: "This Desktop", assignment: .desktop(""), isEnabled: false)])
    }
}
