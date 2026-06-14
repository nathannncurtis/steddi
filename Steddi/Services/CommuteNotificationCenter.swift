import Foundation
import UserNotifications
import os

private let notifLog = Logger(subsystem: "to.nathancurtis.steddi", category: "CommuteNotificationCenter")

extension Notification.Name {
    /// Posted when the user taps "Start Commute" on a commute alert. userInfo
    /// carries the steddi:// deep link so existing handlers can route it.
    static let steddiStartCommuteFromNotification = Notification.Name("steddiStartCommuteFromNotification")
}

/// Thin wrapper over `UNUserNotificationCenter` for the smart-commute alerts.
/// Owns: the COMMUTE_ALERT category + actions, per-commute notification IDs,
/// dedupe against pending requests, cooldown timestamp bookkeeping, and the
/// "Start Commute" deep-link routing through the existing steddi:// scheme.
///
/// Deliberately separate from `ArrivalNotificationService` (which owns the
/// SAVE_ROUTE category) so the two don't fight over the singleton delegate.
final class CommuteNotificationCenter {

    static let shared = CommuteNotificationCenter()

    static let categoryIdentifier = "COMMUTE_ALERT"
    static let startActionIdentifier = "START_COMMUTE"
    static let snoozeActionIdentifier = "REMIND_LATER"
    static let dismissActionIdentifier = "DISMISS_COMMUTE"

    /// Notification identifier prefix — one stable id per commute+direction so a
    /// window never spawns duplicates and we can target removal.
    static let identifierPrefix = "steddi.commute-alert."

    /// Cooldown key prefix mirrors the spec's `steddi.lastCommuteNotificationTime.<id>`.
    static let cooldownKeyPrefix = "steddi.lastCommuteNotificationTime."

    /// How long "Remind Me Later" snoozes.
    static let snoozeSeconds: TimeInterval = 15 * 60

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
    }

    // MARK: - Identifiers

    /// Stable notification id for a commute+direction.
    static func identifier(commuteId: UUID, direction: CommuteDirection) -> String {
        "\(identifierPrefix)\(commuteId.uuidString).\(direction.rawValue)"
    }

    static func cooldownKey(commuteId: UUID) -> String {
        "\(cooldownKeyPrefix)\(commuteId.uuidString)"
    }

    // MARK: - Category Registration

    /// Register the COMMUTE_ALERT category. Merges with any categories another
    /// service already registered so we don't clobber SAVE_ROUTE.
    func registerCategory() async {
        let start = UNNotificationAction(
            identifier: Self.startActionIdentifier,
            title: "Start Commute",
            options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: Self.snoozeActionIdentifier,
            title: "Remind Me Later",
            options: []
        )
        let dismiss = UNNotificationAction(
            identifier: Self.dismissActionIdentifier,
            title: "Dismiss",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [start, snooze, dismiss],
            intentIdentifiers: [],
            options: []
        )

        var existing = await center.notificationCategories()
        existing = existing.filter { $0.identifier != Self.categoryIdentifier }
        existing.insert(category)
        center.setNotificationCategories(existing)
    }

    // MARK: - Cooldown Bookkeeping

    /// When the given commute last fired an alert, nil if never.
    func lastNotificationTime(commuteId: UUID) -> Date? {
        let key = Self.cooldownKey(commuteId: commuteId)
        let t = defaults.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Record that we just notified this commute (for the engine's cooldown).
    func recordNotification(commuteId: UUID, at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.cooldownKey(commuteId: commuteId))
    }

    // MARK: - Scheduling

    /// Schedule (or replace) a commute alert. Dedupes against pending requests
    /// — UNUserNotificationCenter is the source of truth — so a re-run within
    /// the same window won't double-notify. Delivers `leadMinutes` before the
    /// expected departure (or immediately if departure already passed minus
    /// lead, since background passes run close to the window).
    ///
    /// Returns true if a request was added.
    @discardableResult
    func scheduleAlert(
        commuteId: UUID,
        direction: CommuteDirection,
        title: String,
        body: String,
        deepLink: URL,
        fireAfter seconds: TimeInterval
    ) async -> Bool {
        let identifier = Self.identifier(commuteId: commuteId, direction: direction)

        // Dedupe: if an alert for this commute+direction is already pending,
        // leave it. The window is already covered.
        let pending = await center.pendingNotificationRequests()
        if pending.contains(where: { $0.identifier == identifier }) {
            notifLog.debug("commute alert already pending for \(identifier, privacy: .public); skipping")
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [
            "commuteId": commuteId.uuidString,
            "direction": direction.rawValue,
            "deepLink": deepLink.absoluteString
        ]

        // UNTimeIntervalNotificationTrigger requires a strictly positive
        // interval; clamp tiny/negative leads to "fire now-ish".
        let interval = max(1, seconds)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        do {
            try await center.add(request)
            recordNotification(commuteId: commuteId)
            notifLog.info("scheduled commute alert \(identifier, privacy: .public) in \(Int(interval))s")
            return true
        } catch {
            notifLog.error("failed to schedule commute alert: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Cancel a specific commute+direction alert.
    func cancelAlert(commuteId: UUID, direction: CommuteDirection) {
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.identifier(commuteId: commuteId, direction: direction)]
        )
    }

    /// Cancel every pending commute alert (e.g. when notifications are disabled).
    func cancelAllCommuteAlerts() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Deep Link

    /// The Start-Commute deep link, reusing the existing steddi:// scheme.
    static func startCommuteDeepLink(commuteId: UUID, direction: CommuteDirection) -> URL {
        var components = URLComponents()
        components.scheme = "steddi"
        components.host = "navigate"
        components.queryItems = [
            URLQueryItem(name: "commuteId", value: commuteId.uuidString),
            URLQueryItem(name: "direction", value: direction.rawValue)
        ]
        // Safe: fixed scheme/host with URL-encoded query items.
        return components.url!
    }
}
