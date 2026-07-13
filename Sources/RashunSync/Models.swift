import Foundation
import Crypto
import RashunCore

public struct UsageSeriesID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let providerID: String
    public let metricID: String
    public init(providerID: String, metricID: String) { self.providerID = providerID; self.metricID = metricID }
    public var description: String { "\(providerID)::\(metricID)" }
}

public struct OriginID: Hashable, Codable, Sendable {
    public let deviceID: UUID
    public let epoch: UUID
    public init(deviceID: UUID, epoch: UUID) { self.deviceID = deviceID; self.epoch = epoch }
}

public struct DeviceIdentity: Codable, Sendable, Equatable {
    public let deviceID: UUID
    public let epoch: UUID
    public var displayName: String
    public let signingPublicKey: Data
    public init(deviceID: UUID = UUID(), epoch: UUID = UUID(), displayName: String, signingPublicKey: Data) {
        self.deviceID = deviceID; self.epoch = epoch; self.displayName = displayName; self.signingPublicKey = signingPublicKey
    }
}

public enum ObservationStatus: String, Codable, Sendable { case available }

public struct UsageObservation: Codable, Sendable, Identifiable, Equatable {
    public static let schemaVersion: UInt16 = 1
    public let id: UUID
    public let origin: OriginID
    public let originSequence: UInt64
    public let series: UsageSeriesID
    public let observedAt: Date
    public let remaining: Double
    public let limit: Double
    public let resetAt: Date?
    public let cycleStartedAt: Date?
    public let status: ObservationStatus
    public let payloadHash: Data

    public init(id: UUID = UUID(), origin: OriginID, originSequence: UInt64, series: UsageSeriesID,
                observedAt: Date, remaining: Double, limit: Double, resetAt: Date?, cycleStartedAt: Date?,
                status: ObservationStatus = .available, payloadHash: Data? = nil) throws {
        guard originSequence > 0, Self.validID(series.providerID), Self.validID(series.metricID),
              remaining.isFinite, limit.isFinite, remaining >= 0, limit > 0 else { throw SyncValidationError.invalidObservation }
        self.id = id; self.origin = origin; self.originSequence = originSequence; self.series = series
        self.observedAt = observedAt; self.remaining = remaining; self.limit = limit
        self.resetAt = resetAt; self.cycleStartedAt = cycleStartedAt; self.status = status
        self.payloadHash = payloadHash ?? Self.hash(id: id, origin: origin, sequence: originSequence, series: series,
                                                    observedAt: observedAt, remaining: remaining, limit: limit,
                                                    resetAt: resetAt, cycleStartedAt: cycleStartedAt, status: status)
        guard self.payloadHash == Self.hash(id: id, origin: origin, sequence: originSequence, series: series,
                                            observedAt: observedAt, remaining: remaining, limit: limit,
                                            resetAt: resetAt, cycleStartedAt: cycleStartedAt, status: status) else { throw SyncValidationError.hashMismatch }
    }

    public var usageResult: UsageResult { UsageResult(remaining: remaining, limit: limit, resetDate: resetAt, cycleStartDate: cycleStartedAt) }
    private static func validID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) } }
    private static func hash(id: UUID, origin: OriginID, sequence: UInt64, series: UsageSeriesID, observedAt: Date,
                             remaining: Double, limit: Double, resetAt: Date?, cycleStartedAt: Date?, status: ObservationStatus) -> Data {
        let fields = ["1", id.uuidString.lowercased(), origin.deviceID.uuidString.lowercased(), origin.epoch.uuidString.lowercased(),
                      String(sequence), series.providerID, series.metricID, String(observedAt.timeIntervalSince1970.bitPattern),
                      String(remaining.bitPattern), String(limit.bitPattern), resetAt.map { String($0.timeIntervalSince1970.bitPattern) } ?? "-",
                      cycleStartedAt.map { String($0.timeIntervalSince1970.bitPattern) } ?? "-", status.rawValue]
        return Data(SHA256.hash(data: Data(fields.joined(separator: "\u{1f}").utf8)))
    }
}

public enum SyncValidationError: Error, Equatable { case invalidObservation, hashMismatch, originSequenceConflict, payloadTooLarge, incompatibleProtocol }

public struct OriginSummary: Codable, Sendable, Equatable {
    public let origin: OriginID; public let minimum: UInt64; public let maximum: UInt64; public let contiguousThrough: UInt64; public let gaps: [SequenceRange]
}
public struct SequenceRange: Codable, Sendable, Equatable { public let from: UInt64; public let through: UInt64; public init(from:UInt64,through:UInt64){self.from=from;self.through=through} }
