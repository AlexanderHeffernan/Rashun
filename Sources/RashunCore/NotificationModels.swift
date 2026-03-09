import Foundation

public struct NotificationInputSpec {
    public let id: String
    public let label: String
    public let unit: String?
    public let defaultValue: Double
    public let min: Double
    public let max: Double
    public let step: Double

    public init(id: String, label: String, unit: String?, defaultValue: Double, min: Double, max: Double, step: Double) {
        self.id = id
        self.label = label
        self.unit = unit
        self.defaultValue = defaultValue
        self.min = min
        self.max = max
        self.step = step
    }
}

public struct NotificationDefinition {
    public let id: String
    public let title: String
    public let detail: String
    public let inputs: [NotificationInputSpec]
    public let evaluate: (NotificationContext) -> NotificationEvent?

    public init(id: String, title: String, detail: String, inputs: [NotificationInputSpec], evaluate: @escaping (NotificationContext) -> NotificationEvent?) {
        self.id = id
        self.title = title
        self.detail = detail
        self.inputs = inputs
        self.evaluate = evaluate
    }
}

public struct NotificationEvent {
    public let title: String
    public let body: String
    public let cooldownSeconds: TimeInterval?
    public let cycleKey: String?

    public init(title: String, body: String, cooldownSeconds: TimeInterval?, cycleKey: String?) {
        self.title = title
        self.body = body
        self.cooldownSeconds = cooldownSeconds
        self.cycleKey = cycleKey
    }
}

public struct UsageSnapshot: Codable {
    public let timestamp: Date
    public let usage: UsageResult

    public init(timestamp: Date, usage: UsageResult) {
        self.timestamp = timestamp
        self.usage = usage
    }
}

public struct NotificationContext {
    public let sourceName: String
    public let metricId: String?
    public let metricTitle: String?
    public let current: UsageResult
    public let previous: UsageSnapshot?
    public let history: [UsageSnapshot]
    public let inputValue: (String, Double) -> Double

    public init(sourceName: String, metricId: String?, metricTitle: String?, current: UsageResult, previous: UsageSnapshot?, history: [UsageSnapshot], inputValue: @escaping (String, Double) -> Double) {
        self.sourceName = sourceName
        self.metricId = metricId
        self.metricTitle = metricTitle
        self.current = current
        self.previous = previous
        self.history = history
        self.inputValue = inputValue
    }

    public func value(for inputId: String, defaultValue: Double) -> Double {
        inputValue(inputId, defaultValue)
    }

    public func snapshot(minutesAgo: Double) -> UsageSnapshot? {
        guard minutesAgo > 0 else { return nil }
        let target = Date().addingTimeInterval(-minutesAgo * 60)
        return history.last(where: { $0.timestamp <= target })
    }
}
