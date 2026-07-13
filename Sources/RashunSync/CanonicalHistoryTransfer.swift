import Foundation
import RashunCore

public struct CanonicalHistoryExport:Codable,Sendable {public static let schemaVersion=2;public let schemaVersion:Int;public let exportedAt:Date;public let appVersion:String;public let observations:[UsageObservation];public init(exportedAt:Date=Date(),appVersion:String,observations:[UsageObservation]){schemaVersion=Self.schemaVersion;self.exportedAt=exportedAt;self.appVersion=appVersion;self.observations=observations}}
public enum CanonicalHistoryTransfer {
    public static func export(repository:SyncRepository,appVersion:String)throws->Data{let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting=[.prettyPrinted,.sortedKeys];return try encoder.encode(CanonicalHistoryExport(appVersion:appVersion,observations:repository.allObservations()))}
    @discardableResult public static func importData(_ data:Data,repository:SyncRepository,backupRoot:URL)throws->Int{let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        if let canonical=try? decoder.decode(CanonicalHistoryExport.self,from:data){guard canonical.schemaVersion==CanonicalHistoryExport.schemaVersion else{throw UsageHistoryTransferError.unsupportedSchema(canonical.schemaVersion)};return try repository.ingest(canonical.observations).accepted}
        let legacy=try UsageHistoryTransferService.readImportData(from:data);return try LegacyHistoryMigrator.migrate(history:legacy,sourceData:data,repository:repository,backupRoot:backupRoot,registry:LegacyHistoryMigrator.defaultRegistry()).imported
    }
}
