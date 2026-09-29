import XCTest
@testable import DockIt

final class WeatherPlaceTests: XCTestCase {
    func testUSStateBecomesItsPostalCode() {
        XCTAssertEqual(WidgetsModel.abbreviatingState("Cincinnati, Ohio"), "Cincinnati, OH")
        XCTAssertEqual(WidgetsModel.abbreviatingState("Santa Fe, New Mexico"), "Santa Fe, NM")
        // The geocoder's name for the capital, and its admin1.
        XCTAssertEqual(
            WidgetsModel.abbreviatingState("Washington D.C., District of Columbia"), "Washington D.C., DC")
    }

    /// Only a trailing US state changes: the geocoder has no short form for anywhere else, and a
    /// state name as the city is the city.
    func testEverythingElseIsLeftAsWritten() {
        XCTAssertEqual(WidgetsModel.abbreviatingState("Toronto, Ontario"), "Toronto, Ontario")
        XCTAssertEqual(WidgetsModel.abbreviatingState("Cincinnati, OH"), "Cincinnati, OH")
        XCTAssertEqual(WidgetsModel.abbreviatingState("Cincinnati"), "Cincinnati")
        XCTAssertEqual(WidgetsModel.abbreviatingState("Washington, Pennsylvania"), "Washington, PA")
        XCTAssertEqual(WidgetsModel.abbreviatingState(""), "")
    }
}
