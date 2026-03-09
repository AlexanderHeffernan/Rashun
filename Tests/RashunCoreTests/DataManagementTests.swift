import XCTest
@testable import RashunCore

final class DataManagementTests: XCTestCase {
    func testExportImport_roundTripPreservesHistory() throws {
        let input = sampleHistory()

        let data = try UsageHistoryTransferService.makeExportData(historyBySource: input, appVersion: "test")
        let decoded = try UsageHistoryTransferService.readImportData(from: data)

        XCTAssertEqual(decoded.keys.sorted(), input.keys.sorted())
        XCTAssertEqual(decoded["Copilot"]?.count, input["Copilot"]?.count)
        XCTAssertEqual(decoded["Amp"]?.count, input["Amp"]?.count)
        XCTAssertEqual(decoded["Copilot"]?.first?.usage.remaining, input["Copilot"]?.first?.usage.remaining)
        XCTAssertEqual(decoded["Copilot"]?.first?.usage.limit, input["Copilot"]?.first?.usage.limit)
        XCTAssertEqual(decoded["Copilot"]?.first?.usage.resetDate, input["Copilot"]?.first?.usage.resetDate)
        XCTAssertEqual(decoded["Copilot"]?.first?.timestamp, input["Copilot"]?.first?.timestamp)
    }

    func testReadImportData_invalidJsonThrows() {
        let bad = Data("not valid json".utf8)
        XCTAssertThrowsError(try UsageHistoryTransferService.readImportData(from: bad)) { error in
            XCTAssertEqual(error as? UsageHistoryTransferError, .invalidFile)
        }
    }

    func testReadImportData_unsupportedSchemaThrows() throws {
        let iso = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "schemaVersion": UsageHistoryExportFile.currentSchemaVersion + 1,
            "exportedAt": iso.string(from: Date()),
            "appVersion": "9.9.9",
            "historyBySource": [:] as [String: [[String: Any]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        XCTAssertThrowsError(try UsageHistoryTransferService.readImportData(from: data)) { error in
            guard case let UsageHistoryTransferError.unsupportedSchema(version) = error else {
                return XCTFail("Expected unsupportedSchema, got \(error)")
            }
            XCTAssertEqual(version, UsageHistoryExportFile.currentSchemaVersion + 1)
        }
    }

    func testReadImportData_supportsLegacyRawHistoryFormat() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let raw = sampleHistory()
        let data = try encoder.encode(raw)

        let decoded = try UsageHistoryTransferService.readImportData(from: data)
        XCTAssertEqual(decoded["Copilot"]?.count, raw["Copilot"]?.count)
    }

    private func sampleHistory() -> [String: [UsageSnapshot]] {
        [
            "Copilot": [
                UsageSnapshot(
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    usage: UsageResult(
                        remaining: 80,
                        limit: 100,
                        resetDate: Date(timeIntervalSince1970: 1_700_100_000),
                        cycleStartDate: Date(timeIntervalSince1970: 1_699_500_000)
                    )
                )
            ],
            "Amp": [
                UsageSnapshot(
                    timestamp: Date(timeIntervalSince1970: 1_700_200_000),
                    usage: UsageResult(remaining: 10, limit: 10)
                )
            ]
        ]
    }
}
