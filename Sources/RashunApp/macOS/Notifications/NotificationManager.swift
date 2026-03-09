import Foundation
import UserNotifications
import RashunCore

@MainActor
final class NotificationManager {
    enum Route: String {
        case usageHistory
        case preferencesUpdates
    }

    private static let routeUserInfoKey = "rashun.notification.route"

    static let shared = NotificationManager()
    private init() {}

    /// Request user authorization for notifications. Returns true if granted.
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error = error {
                    print("Notification auth error: \(error)")
                }
                continuation.resume(returning: granted)
            }
        }
    }

    /// Send a simple notification with title/body and a route used when the user clicks it.
    func sendNotification(title: String, body: String, route: Route) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [Self.routeUserInfoKey: route.rawValue]

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error)")
            }
        }
    }

    func route(for userInfo: [AnyHashable: Any]) -> Route? {
        guard let rawValue = userInfo[Self.routeUserInfoKey] as? String else {
            return nil
        }
        return Route(rawValue: rawValue)
    }
}
