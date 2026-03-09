import Foundation

public struct NotificationRuleState: Codable {
    public var lastFiredAt: Date?
    public var lastFiredCycleKey: String?

    public init(lastFiredAt: Date?, lastFiredCycleKey: String?) {
        self.lastFiredAt = lastFiredAt
        self.lastFiredCycleKey = lastFiredCycleKey
    }
}

public func shouldSendNotification(event: NotificationEvent, state: NotificationRuleState?) -> Bool {
    if let cycleKey = event.cycleKey, state?.lastFiredCycleKey == cycleKey {
        return false
    }
    if let cooldown = event.cooldownSeconds, let last = state?.lastFiredAt {
        if Date().timeIntervalSince(last) < cooldown {
            return false
        }
    }
    return true
}
