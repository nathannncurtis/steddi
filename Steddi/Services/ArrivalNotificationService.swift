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
        let request = response.notification.request

        // SAVE_ROUTE — post-arrival "save this route?" prompt.
        if request.identifier == ArrivalNotificationService.notificationIdentifier {
            if response.actionIdentifier == "SAVE" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                NotificationCenter.default.post(name: .steddiSaveRouteFromNotification, object: nil)
            }
            return
        }

        // COMMUTE_ALERT — smart-commute departure alert.
        if request.identifier.hasPrefix(CommuteNotificationCenter.identifierPrefix) {
            await handleCommuteAlert(response: response)
        }
    }

    /// Route a COMMUTE_ALERT response: "Start Commute" (or tapping the body)
    /// kicks off navigation via the shared start mechanism; "Remind Me Later"
    /// reschedules the same alert; "Dismiss" does nothing.
    private func handleCommuteAlert(response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let info = content.userInfo

        switch response.actionIdentifier {
        case CommuteNotificationCenter.startActionIdentifier,
             UNNotificationDefaultActionIdentifier:
            await startCommute(from: info)

        case CommuteNotificationCenter.snoozeActionIdentifier:
            await rescheduleCommuteAlert(content: content, info: info)

        default:
            // DISMISS / dismiss-from-banner — nothing to do.
            break
        }
    }

    /// Hand off to the durable start store so the request survives a cold launch
    /// (the .foreground action may relaunch the app before HomeView attaches).
    private func startCommute(from info: [AnyHashable: Any]) async {
        guard let commuteIdStr = info["commuteId"] as? String,
              let commuteId = UUID(uuidString: commuteIdStr) else { return }
        let direction = (info["direction"] as? String).flatMap(CommuteDirection.init(rawValue:))
        await MainActor.run {
            PendingCommuteStartStore.shared.request(
                .specific(commuteId: commuteId, direction: direction)
            )
        }
    }

    /// Re-arm the commute alert ~15 minutes out, preserving its content and
    /// deep link. Cancels the spent request first so the stable per-commute id
    /// can be reused (and so the dedupe check sees a clear slot).
    private func rescheduleCommuteAlert(content: UNNotificationContent, info: [AnyHashable: Any]) async {
        guard let commuteIdStr = info["commuteId"] as? String,
              let commuteId = UUID(uuidString: commuteIdStr),
              let directionStr = info["direction"] as? String,
              let direction = CommuteDirection(rawValue: directionStr),
              let deepLinkStr = info["deepLink"] as? String,
              let deepLink = URL(string: deepLinkStr) else { return }

        let center = CommuteNotificationCenter.shared
        center.cancelAlert(commuteId: commuteId, direction: direction)
        await center.scheduleAlert(
            commuteId: commuteId,
            direction: direction,
            title: content.title,
            body: content.body,
            deepLink: deepLink,
            fireAfter: CommuteNotificationCenter.snoozeSeconds
        )
    }
}
