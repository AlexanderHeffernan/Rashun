import Foundation

public struct UsageHistoryExportFile: Codable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let appVersion: String
    public let historyBySource: [String: [UsageSnapshot]]

    public static let currentSchemaVersion = 1

    public init(schemaVersion: Int, exportedAt: Date, appVersion: String, historyBySource: [String: [UsageSnapshot]]) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.historyBySource = historyBySource
    }
}

public enum UsageHistoryTransferError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidFile

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported history export schema version: \(version)."
        case .invalidFile:
            return "Selected file is not a valid usage history export."
        }
    }
}

public enum UsageHistoryTransferService {
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

    public static func makeExportData(historyBySource: [String: [UsageSnapshot]], appVersion: String) throws -> Data {
        let payload = UsageHistoryExportFile(
            schemaVersion: UsageHistoryExportFile.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            historyBySource: historyBySource
        )
        return try encoder.encode(payload)
    }

    public static func readImportData(from data: Data) throws -> [String: [UsageSnapshot]] {
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
