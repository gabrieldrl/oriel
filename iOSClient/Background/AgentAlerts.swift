import UIKit
import UserNotifications

/// The notifications a Mac pushes when an agent finishes (docs/background-plan.md): iOS shows them
/// itself while Sill is in the background; this shows them as a banner while it is in front too, and
/// passes the device's push token to MacLinks.
final class AgentAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentAlerts()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
