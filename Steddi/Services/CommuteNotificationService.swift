import Foundation
import BackgroundTasks
import CoreLocation
import SwiftData
import UserNotifications
import os

private let serviceLog = Logger(subsystem: "to.nathancurtis.steddi", category: "CommuteNotificationService")

/// @Observable orchestrator for fully on-device smart commute notifications.
///
/// Responsibilities:
/// - Register & schedule the BGAppRefreshTask around learned/scheduled
///   departure windows.
/// - Run the background pass: for each active commute, gather inputs (learned
///   departure hours, current ETA vs typical, weather), ask the pure decision
///   engine, and dispatch through `CommuteNotificationCenter`.
/// - Own the thoughtful permission flow (NOT at first launch).
///
/// Everything stateful and platform-y lives here; the actual notify/skip call
/// is the pure `CommuteNotificationDecisionEngine`.
@Observable
final class CommuteNotificationService {

    /// BGAppRefreshTask identifier — must also be in Info.plist
    /// BGTaskSchedulerPermittedIdentifiers.
    static let backgroundTaskIdentifier = "to.nathancurtis.steddi.commutecheck"

    /// AppStorage-style global toggle key.
    static let globalEnabledKey = "steddi.commuteNotificationsGlobalEnabled"
    /// Weather sensitivity key (raw value of `WeatherSensitivity`).
    static let weatherSensitivityKey = "steddi.weatherAlertThreshold"
    /// Tracks whether we've already shown the pre-permission explainer, so we
    /// only ask once.
    static let permissionRequestedKey = "steddi.commuteNotificationPermissionRequested"
    /// When the background schedule was last (re)computed — re-derive weekly.
    static let lastScheduleKey = "steddi.commuteNotificationLastSchedule"

    /// Minimum trips on the same day-of-week before we trust a learned pattern.
    static let learnedConfidenceMinTrips = 5

    /// How far before a departure window to wake up (seconds). iOS won't honor
    /// this exactly; we re-arm each run to keep coverage.
    static let refreshLeadSeconds: TimeInterval = 60 * 60  // ~1h before

    // MARK: Dependencies

    private let modelContainer: ModelContainer
    private let weatherService: CommuteWeatherService
    private let notificationCenter: CommuteNotificationCenter
    private let directionsService: DirectionsService
    private let locationProvider: () -> CLLocation?
    private let defaults: UserDefaults

    // MARK: Observable State

    /// Mirrors UNAuthorizationStatus for Settings UI.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init(
        modelContainer: ModelContainer,
        weatherService: CommuteWeatherService = CommuteWeatherService(),
        notificationCenter: CommuteNotificationCenter = .shared,
        directionsService: DirectionsService = DirectionsService(),
        locationProvider: @escaping () -> CLLocation? = { nil },
        defaults: UserDefaults = .standard
    ) {
        self.modelContainer = modelContainer
        self.weatherService = weatherService
        self.notificationCenter = notificationCenter
        self.directionsService = directionsService
        self.locationProvider = locationProvider
        self.defaults = defaults
    }

    // MARK: - Settings Accessors

    var globallyEnabled: Bool {
        // Default true when never set.
        defaults.object(forKey: Self.globalEnabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.globalEnabledKey)
    }

    var weatherSensitivity: WeatherSensitivity {
        WeatherSensitivity(rawValue: defaults.string(forKey: Self.weatherSensitivityKey) ?? "")
            ?? .harsh
    }

    // MARK: - Permission Flow (thoughtful, not at first launch)

    /// Refresh `authorizationStatus` from the system.
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Whether we should still surface the pre-permission explainer. True only
    /// when undetermined and we haven't asked yet — callers gate the request on
    /// a meaningful moment (creating a commute, opening Settings), never launch.
    func shouldOfferPermissionPrompt() async -> Bool {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined else { return false }
        return !defaults.bool(forKey: Self.permissionRequestedKey)
    }

    /// Request notification authorization. Call after the user has seen an
    /// explanatory sheet. Idempotent — records that we asked.
    @discardableResult
    func requestAuthorization() async -> Bool {
        defaults.set(true, forKey: Self.permissionRequestedKey)
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            if granted {
                await notificationCenter.registerCategory()
                scheduleBackgroundRefresh()
            }
            return granted
        } catch {
            serviceLog.error("auth request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Background Task Registration

    /// Register the BGAppRefreshTask handler. Call once in
    /// didFinishLaunchingWithOptions, before the app finishes launching.
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundRefresh(refreshTask)
        }
        serviceLog.info("registered background task \(Self.backgroundTaskIdentifier, privacy: .public)")
    }

    /// Schedule the next background refresh near the earliest upcoming departure
    /// window across active commutes. Falls back to schedule rules, then skips
    /// entirely when neither exists (per spec).
    func scheduleBackgroundRefresh() {
        guard globallyEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
            return
        }

        let earliest = nextDepartureDate()
        guard let earliest else {
            serviceLog.info("no learned/scheduled departures; skipping background scheduling")
            return
        }

        let beginDate = earliest.addingTimeInterval(-Self.refreshLeadSeconds)
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        // Never request a past begin date.
        request.earliestBeginDate = max(beginDate, Date().addingTimeInterval(60))

        do {
            try BGTaskScheduler.shared.submit(request)
            defaults.set(Date(), forKey: Self.lastScheduleKey)
            serviceLog.info("scheduled background refresh for \(request.earliestBeginDate?.description ?? "nil", privacy: .public)")
        } catch {
            serviceLog.error("failed to submit BGAppRefreshTask: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        // Always re-arm so coverage continues even if this run is cut short.
        scheduleBackgroundRefresh()

        let work = Task {
            await runNotificationPass()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    // MARK: - Notification Pass

    /// Evaluate every active commute and dispatch alerts where the engine says
    /// notify. Safe to call from the background task or a manual trigger.
    func runNotificationPass(now: Date = Date()) async {
        guard globallyEnabled else { return }

        let context = ModelContext(modelContainer)
        let commutes: [Commute]
        do {
            commutes = try context.fetch(
                FetchDescriptor<Commute>(predicate: #Predicate { $0.isActive })
            )
        } catch {
            serviceLog.error("failed to fetch commutes: \(error.localizedDescription, privacy: .public)")
            return
        }

        let allTrips = (try? context.fetch(FetchDescriptor<CommuteTrip>())) ?? []

        for commute in commutes {
            await evaluateAndDispatch(commute: commute, allTrips: allTrips, now: now)
        }
    }

    private func evaluateAndDispatch(commute: Commute, allTrips: [CommuteTrip], now: Date) async {
        guard commute.notificationsEnabled else { return }

        // Direction for this window: schedule rules first, then next-scheduled.
        let direction = CommuteDirectionResolver.scheduledDirection(commute: commute, now: now)
            ?? CommuteDirectionResolver.nextScheduledDirection(commute: commute, now: now)
            ?? .originToDestination

        let learned = Self.learnedDepartureHours(commute: commute, trips: allTrips, now: now)
        let scheduled = Self.scheduledDepartureHours(commute: commute, direction: direction)
        let expectedHours = learned.isEmpty ? scheduled : learned

        // Resolve destination coordinate + name for the chosen direction.
        let (destCoord, destName) = destination(for: commute, direction: direction)

        // ETA: requires both a current location and a destination coordinate.
        // A failed fetch (network/invalid coords) must not be silently swallowed
        // — log it so a suppressed notification is diagnosable. The decision
        // engine falls back to the typical duration below when currentETA is nil.
        var currentETA: TimeInterval?
        if let here = locationProvider()?.coordinate, let dest = destCoord {
            do {
                currentETA = try await directionsService.fetchDirectETA(from: here, to: dest)
            } catch {
                serviceLog.notice("ETA fetch failed for \(commute.name, privacy: .public); falling back to typical duration: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Typical baseline: preferred route's stored typical duration.
        let typical = commute.preferredRoute(for: direction)?.typicalDurationSeconds

        // Weather for the destination (degrades to .unavailable gracefully).
        let weather: WeatherCondition
        if let dest = destCoord {
            weather = await weatherService.condition(for: dest)
        } else {
            weather = .unavailable
        }

        let input = CommuteNotificationDecisionEngine.Input(
            notificationsEnabled: commute.notificationsEnabled,
            globallyEnabled: globallyEnabled,
            leadMinutes: commute.notificationLeadMinutes,
            quietHoursStart: commute.quietHoursStart,
            quietHoursEnd: commute.quietHoursEnd,
            expectedDepartureHours: expectedHours,
            fromLearnedHistory: !learned.isEmpty,
            currentETA: currentETA,
            typicalDuration: typical,
            weather: weather,
            weatherSensitivity: weatherSensitivity,
            lastNotificationTime: notificationCenter.lastNotificationTime(commuteId: commute.id),
            now: now,
            destinationName: destName
        )

        let decision = CommuteNotificationDecisionEngine.evaluate(input)
        switch decision {
        case .skip(let reason):
            serviceLog.debug("skip \(commute.name, privacy: .public): \(reason, privacy: .public)")
        case .notify(let message, let actionType, let leadMinutes):
            let title = Self.title(for: actionType, leadMinutes: leadMinutes)
            let deepLink = CommuteNotificationCenter.startCommuteDeepLink(
                commuteId: commute.id, direction: direction
            )
            // Fire roughly now — the background pass already runs close to the
            // departure window. A tiny delay keeps the trigger valid.
            await notificationCenter.scheduleAlert(
                commuteId: commute.id,
                direction: direction,
                title: title,
                body: message,
                deepLink: deepLink,
                fireAfter: 1
            )
        }
    }

    // MARK: - Pattern Analysis

    /// Learned departure hours for today's day-of-week, derived from CommuteTrip
    /// history. Requires >= `learnedConfidenceMinTrips` matching trips. Returns
    /// the distinct hours users actually departed (clustered by hour).
    static func learnedDepartureHours(
        commute: Commute,
        trips: [CommuteTrip],
        now: Date,
        calendar: Calendar = .current
    ) -> [Int] {
        let dayOfWeek = calendar.component(.weekday, from: now)
        let relevant = trips.filter { $0.commute?.id == commute.id && $0.dayOfWeek == dayOfWeek }
        guard relevant.count >= learnedConfidenceMinTrips else { return [] }

        // Count departures per hour; keep hours seen on >= 20% of matching days
        // so a one-off outlier doesn't create a phantom window. Compared as a
        // double so a single occurrence in a large sample (e.g. 1 of 9 ≈ 11%)
        // is correctly dropped rather than rounded up to the floor.
        var counts: [Int: Int] = [:]
        for trip in relevant { counts[trip.hourOfDay, default: 0] += 1 }
        let floor = Double(relevant.count) * 0.2
        return counts.filter { Double($0.value) >= floor }.keys.sorted()
    }

    /// Schedule-rule departure hours for the given direction (zero-history
    /// fallback). The window start hour is the expected departure.
    static func scheduledDepartureHours(
        commute: Commute,
        direction: CommuteDirection
    ) -> [Int] {
        switch direction {
        case .originToDestination:
            return commute.scheduleToDestStartHour.map { [$0] } ?? []
        case .destinationToOrigin:
            return commute.scheduleToOriginStartHour.map { [$0] } ?? []
        }
    }

    // MARK: - Helpers

    /// Next departure Date across all active commutes (learned or scheduled),
    /// used to time the background refresh. nil when nothing is known.
    private func nextDepartureDate() -> Date? {
        let context = ModelContext(modelContainer)
        guard let commutes = try? context.fetch(
            FetchDescriptor<Commute>(predicate: #Predicate { $0.isActive })
        ) else { return nil }
        let trips = (try? context.fetch(FetchDescriptor<CommuteTrip>())) ?? []

        let cal = Calendar.current
        let now = Date()
        var best: Date?

        for commute in commutes where commute.notificationsEnabled {
            // Candidate hours over the next 7 days from learned + scheduled rules.
            for dayOffset in 0...7 {
                guard let day = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
                let learned = Self.learnedDepartureHours(commute: commute, trips: trips, now: day, calendar: cal)
                let toDest = commute.scheduleToDestStartHour.map { [$0] } ?? []
                let toOrigin = commute.scheduleToOriginStartHour.map { [$0] } ?? []
                let hours = Set(learned + toDest + toOrigin)
                for hour in hours {
                    guard let candidate = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day),
                          candidate > now else { continue }
                    best = best.map { min($0, candidate) } ?? candidate
                }
            }
        }
        return best
    }

    /// Destination coordinate + display name for a direction.
    private func destination(
        for commute: Commute,
        direction: CommuteDirection
    ) -> (CLLocationCoordinate2D?, String) {
        switch direction {
        case .originToDestination:
            if let d = commute.destination {
                return (CLLocationCoordinate2D(latitude: d.latitude, longitude: d.longitude), d.name)
            }
            return (nil, commute.destination?.name ?? "your destination")
        case .destinationToOrigin:
            if let o = commute.origin {
                return (CLLocationCoordinate2D(latitude: o.latitude, longitude: o.longitude), o.name)
            }
            return (nil, commute.origin?.name ?? "your destination")
        }
    }

    /// Title copy keyed to the action type and lead time.
    static func title(for actionType: NotificationActionType, leadMinutes: Int) -> String {
        switch actionType {
        case .leaveEarly:
            return "Leave \(leadMinutes) minutes early?"
        case .harshWeather:
            return "Heads up before you head out"
        case .combinedDelay:
            return "Leave \(leadMinutes) minutes early?"
        }
    }
}
