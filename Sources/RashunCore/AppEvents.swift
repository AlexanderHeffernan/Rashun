import Foundation

public extension Notification.Name {
    static let aiSettingsChanged = Notification.Name("ai.settings.changed")
    static let aiDataRefreshed = Notification.Name("ai.data.refreshed")
    static let aiSourceHealthChanged = Notification.Name("ai.sourceHealth.changed")
    static let updateStatusChanged = Notification.Name("ai.update.statusChanged")
}
