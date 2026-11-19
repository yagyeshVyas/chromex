import Foundation
import UserNotifications

/// Presents `chrome.notifications.create` calls as local notifications.
///
/// WebKit gives an app no system surface by itself; UserNotifications is the
/// only sanctioned one, and it works in the foreground when a delegate opts in.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationPresenter()

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func post(title: String, body: String, identifier: String, completion: @escaping (Bool) -> Void) {
        let box = SendableBox(completion)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                Task { @MainActor in box.value(false) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request) { error in
                Task { @MainActor in box.value(error == nil) }
            }
        }
    }
}
