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
}
