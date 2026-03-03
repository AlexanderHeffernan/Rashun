import Foundation

struct UsageResult: Codable {
    let remaining: Double
    let limit: Double
    let resetDate: Date?
    let cycleStartDate: Date?

    init(remaining: Double, limit: Double, resetDate: Date? = nil, cycleStartDate: Date? = nil) {
        self.remaining = remaining
        self.limit = limit
        self.resetDate = resetDate
        self.cycleStartDate = cycleStartDate
    }

    var percentRemaining: Double {
        guard limit > 0 else { return 0 }
        return (remaining / limit) * 100
    }

    var formatted: String {
        String(format: "%.1f%%", percentRemaining)
    }
}

protocol AISource: Sendable {
    // Unique name for this source (shown in menu and settings)
    var name: String { get }
    /// Human-readable requirements or hints for using this source (shown in Preferences)
    var requirements: String { get }
    var supportsPacingAlert: Bool { get }
    func pacingLookbackStart(current: UsageResult, history: [UsageSnapshot], now: Date) -> Date?
    func fetchUsage() async throws -> UsageResult
    var notificationDefinitions: [NotificationDefinition] { get }
    var customNotificationDefinitions: [NotificationDefinition] { get }
    func forecast(current: UsageResult, history: [UsageSnapshot]) -> ForecastResult?
}

extension AISource {
    var requirements: String { "" }
    var supportsPacingAlert: Bool { false }
    func pacingLookbackStart(current: UsageResult, history: [UsageSnapshot], now: Date) -> Date? {
        current.cycleStartDate
    }
    var customNotificationDefinitions: [NotificationDefinition] { [] }
    var notificationDefinitions: [NotificationDefinition] {
        NotificationDefinitions.generic(
            sourceName: name,
            supportsPacingAlert: supportsPacingAlert,
            pacingLookbackStart: { context, now in
                self.pacingLookbackStart(current: context.current, history: context.history, now: now)
            }
        ) + customNotificationDefinitions
    }
    func forecast(current: UsageResult, history: [UsageSnapshot]) -> ForecastResult? { nil }
}

struct ForecastPoint: Sendable {
    let date: Date
    let value: Double
}

struct ForecastResult: Sendable {
    let points: [ForecastPoint]
    let summary: String
}

enum LinearRegression {
    static func slope(xs: [Double], ys: [Double]) -> Double? {
        let n = Double(xs.count)
        guard n >= 2 else { return nil }
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).map(*).reduce(0, +)
        let sumX2 = xs.map { $0 * $0 }.reduce(0, +)
        let denom = n * sumX2 - sumX * sumX
        guard denom != 0 else { return nil }
        return (n * sumXY - sumX * sumY) / denom
    }
}
