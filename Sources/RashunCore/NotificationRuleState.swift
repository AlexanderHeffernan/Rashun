import Foundation

public struct NotificationRuleState: Codable, Sendable, Equatable {
    public var lastFiredAt: Date?
    public var lastFiredCycleKey: String?

    public init(lastFiredAt: Date?, lastFiredCycleKey: String?) {
        self.lastFiredAt = lastFiredAt
        self.lastFiredCycleKey = lastFiredCycleKey
    }
}

public func shouldSendNotification(
    event: NotificationEvent, state: NotificationRuleState?, now: Date = Date()
) -> Bool {
    if let cycleKey = event.cycleKey, state?.lastFiredCycleKey == cycleKey {
        return false
    }
    if let cooldown = event.cooldownSeconds, let last = state?.lastFiredAt {
        if now.timeIntervalSince(last) < cooldown {
            return false
        }
    }
    return true
}

public struct EvaluatedNotification: Sendable, Equatable {
    public let eventID: String
    public let ruleID: String
    public let sourceID: String
    public let metricID: String?
    public let title: String
    public let body: String
    public let state: NotificationRuleState
}
public enum NotificationEvaluator {
    public static func evaluate(
        definition: NotificationDefinition, context: NotificationContext,
        state: NotificationRuleState?,
        now: Date
    ) -> EvaluatedNotification? {
        guard let event = definition.evaluate(context),
            shouldSendNotification(event: event, state: state, now: now)
        else { return nil }
        let cycle = event.cycleKey ?? "none"
        let crossing =
            context.previous.map { String($0.timestamp.timeIntervalSince1970.bitPattern) }
            ?? "initial"
        let identity = [
            "v1", context.sourceName, context.metricId ?? "default", definition.id, cycle, crossing,
            String(context.current.remaining.bitPattern), String(context.current.limit.bitPattern),
        ].map { $0.replacingOccurrences(of: "|", with: "%7C") }.joined(separator: "|")
        return .init(
            eventID: identity, ruleID: definition.id, sourceID: context.sourceName,
            metricID: context.metricId, title: event.title, body: event.body,
            state: .init(lastFiredAt: now, lastFiredCycleKey: event.cycleKey))
    }
}
