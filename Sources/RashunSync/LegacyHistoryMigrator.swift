import Foundation
import Crypto
import RashunCore

public struct MigrationReport: Sendable { public let imported: Int; public let quarantined: [String]; public let backupURL: URL }

public enum LegacyHistoryMigrator {
    public static func migrate(history: [String: [UsageSnapshot]], sourceData: Data, repository: SyncRepository,
                               backupRoot: URL, registry: [String: UsageSeriesID]) throws -> MigrationReport {
        let fingerprint = Data(SHA256.hash(data: sourceData)).map { String(format: "%02x", $0) }.joined()
        let backup = backupRoot.appendingPathComponent(fingerprint, isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let original = backup.appendingPathComponent("ai.notificationHistory.v1.json")
        if !FileManager.default.fileExists(atPath: original.path) { try sourceData.write(to: original, options: [.atomic]) }
        var observations:[UsageObservation]=[], quarantined: [String] = []
        let legacyOrigin = OriginID(deviceID: deterministicUUID("device:\(fingerprint)"), epoch: deterministicUUID("epoch:\(fingerprint)"))
        var sequence: UInt64 = 1
        for key in history.keys.sorted() {
            guard let series = resolve(key, registry: registry) else { quarantined.append(key); continue }
            let sorted = history[key, default: []].enumerated().sorted { a, b in a.element.timestamp == b.element.timestamp ? a.offset < b.offset : a.element.timestamp < b.element.timestamp }
            for (_, snapshot) in sorted {
                let name = "\(fingerprint)|\(series.description)|\(snapshot.timestamp.timeIntervalSince1970.bitPattern)|\(snapshot.usage.remaining.bitPattern)|\(snapshot.usage.limit.bitPattern)|\(sequence)"
                let observation = try UsageObservation(id: deterministicUUID(name), origin: legacyOrigin, originSequence: sequence, series: series,
                    observedAt: snapshot.timestamp, remaining: snapshot.usage.remaining, limit: snapshot.usage.limit, resetAt: snapshot.usage.resetDate, cycleStartedAt: snapshot.usage.cycleStartDate)
                observations.append(observation); sequence += 1
            }
        }
        if !quarantined.isEmpty { try JSONEncoder().encode(quarantined).write(to: backup.appendingPathComponent("quarantine.json"), options: .atomic) }
        let imported=try repository.importMigration(observations,fingerprint:fingerprint,backupPath:backup.path,quarantinedCount:quarantined.count)
        return MigrationReport(imported: imported, quarantined: quarantined, backupURL: backup)
    }

    public static func defaultRegistry() -> [String: UsageSeriesID] {
        var result: [String: UsageSeriesID] = [:]
        for source in allSources { for metric in source.metrics {
            let id = UsageSeriesID(providerID: source.name, metricID: metric.id)
            result["\(source.name)::\(metric.id)"] = id
            result["\(source.name) - \(metric.title)"] = id
            if source.metrics.count == 1 { result[source.name] = id }
        }}
        return result
    }

    private static func resolve(_ key: String, registry: [String: UsageSeriesID]) -> UsageSeriesID? { registry[key] }
    private static func deterministicUUID(_ value: String) -> UUID {
        var bytes = Array(Insecure.SHA1.hash(data: Data(value.utf8)).prefix(16)); bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }
}
