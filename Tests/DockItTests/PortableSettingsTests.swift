import XCTest
@testable import DockIt

final class PortableSettingsTests: XCTestCase {
    func testRoundTrip() throws {
        let original = PortableSettings(
            edge: "left", iconSize: 40, iconPadding: 4, dockPadding: 6, magnifies: true, magnifiedSize: 51,
            smoothHover: true, hoverIntensity: 14, bouncesOnLaunch: false, autoHides: true,
            showsMenuBarIcon: true, pinnedApps: ["/Applications/Safari.app"], stacks: ["/Users/me/Downloads"],
            hiddenApps: []
        )
        XCTAssertEqual(try PortableSettings.decoded(from: original.encoded()), original)
    }

    /// A file from another DockIt version carries only some keys; the rest must stay unset rather than
    /// fail the whole import.
    func testPartialFileDecodes() throws {
        let partial = try PortableSettings.decoded(from: Data(#"{"iconSize": 64, "futureSetting": 1}"#.utf8))
        XCTAssertEqual(partial.iconSize, 64)
        XCTAssertNil(partial.pinnedApps)
    }

    /// Same settings, same bytes — how sync recognises a file it already agrees with.
    func testEncodingIsStable() throws {
        let settings = PortableSettings(iconSize: 48, pinnedApps: ["/b.app", "/a.app"])
        XCTAssertEqual(try settings.encoded(), try settings.encoded())
    }

    /// An old export carries only the points-based size. Converted the way both the defaults
    /// migration and `apply()` convert it: clamped to 1...2.5, snapped to the slider's 0.05 steps.
    func testLegacyMagnifiedSizeConverts() throws {
        let legacy = try PortableSettings.decoded(from: Data(#"{"magnifiedSize": 42}"#.utf8))
        XCTAssertNil(legacy.magnifyAmount)
        let size = try XCTUnwrap(legacy.magnifiedSize)
        // 42 / 36 = 1.1666…, which the slider cannot land on.
        XCTAssertEqual(legacyMagnifyAmount(magnifiedSize: size, iconSize: 36), 1.15, accuracy: 1e-9)
        XCTAssertEqual(legacyMagnifyAmount(magnifiedSize: 500, iconSize: 48), 2.5, accuracy: 1e-9)
        XCTAssertEqual(legacyMagnifyAmount(magnifiedSize: 20, iconSize: 48), 1.0, accuracy: 1e-9)
    }

    /// A hostile or hand-edited file must not carry values the Settings sliders cannot display.
    func testClampedPullsNumbersIntoSliderRanges() throws {
        let hostile = try PortableSettings.decoded(from: Data(#"""
            {"iconSize": 1e20, "iconPadding": -5, "dockPadding": 99, "magnifyAmount": 0.1,
             "magnifyReach": 50, "hoverIntensity": -1, "previewDelay": 1e20, "revealSensitivity": 0,
             "revealDelay": -3, "hideDelay": 7, "revealSpeed": 0, "hideSpeed": 1e20}
            """#.utf8)).clamped()
        XCTAssertEqual(hostile.iconSize, 128)
        XCTAssertEqual(hostile.iconPadding, 0)
        XCTAssertEqual(hostile.dockPadding, 24)
        XCTAssertEqual(hostile.magnifyAmount, 1)
        XCTAssertEqual(hostile.magnifyReach, 4)
        XCTAssertEqual(hostile.hoverIntensity, 0)
        XCTAssertEqual(hostile.previewDelay, 2)
        XCTAssertEqual(hostile.revealSensitivity, 1)
        XCTAssertEqual(hostile.revealDelay, 0)
        XCTAssertEqual(hostile.hideDelay, 2)
        XCTAssertEqual(hostile.revealSpeed, 0.25)
        XCTAssertEqual(hostile.hideSpeed, 4)
    }

    /// In-range values and absent keys pass through untouched.
    func testClampedKeepsSaneValues() {
        let sane = PortableSettings(iconSize: 48, magnifyAmount: 1.35, revealDelay: 0.5)
        XCTAssertEqual(sane.clamped(), sane)
    }
}
