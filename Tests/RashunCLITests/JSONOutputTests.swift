import XCTest
@testable import RashunCLI

final class JSONOutputTests: XCTestCase {
    func testEncoderUsesSortedKeys() throws {
        struct Payload: Encodable {
            let zeta: Int
            let alpha: Int
        }

        let data = try JSONOutput.encoder.encode(Payload(zeta: 2, alpha: 1))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(text, "{\"alpha\":1,\"zeta\":2}")
    }

    func testEncoderUsesISO8601Dates() throws {
        struct Payload: Encodable {
            let timestamp: Date
        }

        let date = Date(timeIntervalSince1970: 0)
        let data = try JSONOutput.encoder.encode(Payload(timestamp: date))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"timestamp\":\"1970-01-01T00:00:00Z\""))
    }
}
