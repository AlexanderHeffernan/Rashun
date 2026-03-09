import Foundation

public struct SourceFetchErrorPresentation: Codable {
    public let shortMessage: String
    public let detailedMessage: String

    public init(shortMessage: String, detailedMessage: String) {
        self.shortMessage = shortMessage
        self.detailedMessage = detailedMessage
    }
}

public struct UsageResult: Codable, Sendable {
    public let remaining: Double
    public let limit: Double
    public let resetDate: Date?
    public let cycleStartDate: Date?

    public init(remaining: Double, limit: Double, resetDate: Date? = nil, cycleStartDate: Date? = nil) {
        self.remaining = remaining
        self.limit = limit
        self.resetDate = resetDate
        self.cycleStartDate = cycleStartDate
    }

    public var percentRemaining: Double {
        guard limit > 0 else { return 0 }
        return (remaining / limit) * 100
    }

    public var formatted: String {
        String(format: "%.1f%%", percentRemaining)
    }
}

public struct AISourceMetric: Sendable, Hashable {
    public let id: String
    public let title: String
    public let defaultEnabled: Bool

    public init(id: String, title: String, defaultEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.defaultEnabled = defaultEnabled
    }
}
