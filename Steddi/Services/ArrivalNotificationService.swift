import Foundation
import UserNotifications

extension Notification.Name {
    static let steddiSaveRouteFromNotification = Notification.Name("steddiSaveRouteFromNotification")
}

/// Schedules a local notification after arrival to offer saving a recorded route.
/// Only fires if the commute doesn't already have a preferred route for that direction.
final class ArrivalNotificationService {
    static let shared = ArrivalNotificationService()
    static let notificationIdentifier = "steddi.save-route"
    static let categoryIdentifier = "SAVE_ROUTE"

    private init() {}

    /// Request notification permission if not already granted.
    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    /// Register the SAVE_ROUTE category with actions. Reads the current set and
    /// unions in SAVE_ROUTE so this never clobbers categories another service
    /// already registered (e.g. COMMUTE_ALERT) — `setNotificationCategories`
    /// replaces the whole set, so a blind set would silently drop the others.
    func registerCategory() {
        let saveAction = UNNotificationAction(identifier: "SAVE", title: "Save Route", options: .foreground)
        let dismissAction = UNNotificationAction(identifier: "DISMISS", title: "Not Now", options: .destructive)
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [saveAction, dismissAction],
            intentIdentifiers: []
        )
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            var merged = existing.filter { $0.identifier != Self.categoryIdentifier }
            merged.insert(category)
            center.setNotificationCategories(merged)
        }
    }

    /// Schedule a "save this route?" notification 2 minutes from now.
    func scheduleRoutePrompt(commuteName: String, destinationName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Route recorded"
        content.body = "Want to save this route for your \(commuteName) commute to \(destinationName)?"
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 120, repeats: false) // 2 minutes

        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Cancel any pending route prompt.
    func cancelPending() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.notificationIdentifier]
        )
    }

    /// Set up as the notification delegate to handle user tapping the notification.
    func setupDelegate() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }
}

/// Handles notification responses — when user taps "Save Route"
class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    // Show notification even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if response.notification.request.identifier == ArrivalNotificationService.notificationIdentifier {
            if response.actionIdentifier == "SAVE" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                NotificationCenter.default.post(name: .steddiSaveRouteFromNotification, object: nil)
            }
        }
    }
}
