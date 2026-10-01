import XCTest
@testable import DockPlus

/// Which unreadable iCloud file is a newer DockPlus's, and so must be left alone, and which is
/// corrupt, and so is replaced. Mistaking the first for the second lost the newer Mac's settings.
final class SettingsSyncDecodeTests: XCTestCase {
    private func decodingError(_ json: String) -> (any Error)? {
        do {
            _ = try PortableSettings.decoded(from: Data(json.utf8))
            return nil
        } catch {
            return error
        }
    }

    /// A setting whose type changed in a newer schema fails on that setting, with its path.
    func testNewerSchemaIsATypeMismatchAtASetting() throws {
        let error = try XCTUnwrap(decodingError(#"{"iconSize":"x"}"#))
        guard let decoding = error as? DecodingError, case .typeMismatch(_, let context) = decoding else {
            return XCTFail("expected a type mismatch, got \(error)")
        }
        XCTAssertFalse(context.codingPath.isEmpty)
        XCTAssertTrue(PortableSettings.isFromNewerDockPlus(error))
    }

    /// Valid JSON that is not an object is corrupt in every schema, so it is replaced rather than
    /// waited out — though it too fails as a type mismatch, at the top.
    func testNonObjectIsCorruptNotNewer() throws {
        let error = try XCTUnwrap(decodingError("[]"))
        XCTAssertFalse(PortableSettings.isFromNewerDockPlus(error))
    }

    func testNonJSONIsCorruptNotNewer() throws {
        let error = try XCTUnwrap(decodingError("not json"))
        XCTAssertFalse(PortableSettings.isFromNewerDockPlus(error))
    }
}
