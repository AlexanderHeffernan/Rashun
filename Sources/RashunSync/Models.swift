import Foundation

public struct UsageSeriesID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let providerID: String
    public let metricID: String
    public init(providerID: String, metricID: String) {
        self.providerID = providerID
        self.metricID = metricID
    }
    public var description: String { "\(providerID)::\(metricID)" }
}

public struct DeviceIdentity: Codable, Sendable, Equatable {
    public let deviceID: UUID
    public let epoch: UUID
    public var displayName: String
    public init(deviceID: UUID = UUID(), epoch: UUID = UUID(), displayName: String) {
        self.deviceID = deviceID
        self.epoch = epoch
        self.displayName = displayName
    }
}

public enum SyncValidationError: Error, Equatable {
    case incompatibleProtocol
}
