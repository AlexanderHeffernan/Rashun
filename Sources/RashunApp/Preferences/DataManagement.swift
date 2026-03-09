import Foundation
import RashunCore

struct UsageHistoryExportFile: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let historyBySource: [String: [UsageSnapshot]]

    static let currentSchemaVersion = 1
}

enum UsageHistoryTransferError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidFile

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported history export schema version: \(version)."
        case .invalidFile:
            return "Selected file is not a valid usage history export."
        }
    }
}

enum UsageHistoryTransferService {
    private static let appVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func makeExportData(historyBySource: [String: [UsageSnapshot]]) throws -> Data {
        let payload = UsageHistoryExportFile(
            schemaVersion: UsageHistoryExportFile.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            historyBySource: historyBySource
        )
        return try encoder.encode(payload)
    }

    static func readImportData(from data: Data) throws -> [String: [UsageSnapshot]] {
        if let payload = try? decoder.decode(UsageHistoryExportFile.self, from: data) {
            guard payload.schemaVersion <= UsageHistoryExportFile.currentSchemaVersion else {
                throw UsageHistoryTransferError.unsupportedSchema(payload.schemaVersion)
            }
            return payload.historyBySource
        }

        if let raw = try? decoder.decode([String: [UsageSnapshot]].self, from: data) {
            return raw
        }

        throw UsageHistoryTransferError.invalidFile
    }
}
