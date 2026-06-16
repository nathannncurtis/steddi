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
    /// Current coordinate for the off-actor notification/idle-ETA pass. `@Sendable`
    /// and coordinate-typed (not `CLLocation`) so it can be invoked safely from the
    /// cooperative pool without touching `@MainActor LocationService` state — the
    /// default supplies the lock-guarded process-wide `LastKnownLocation`.
    private let locationProvider: @Sendable () -> CLLocationCoordinate2D?
    private let defaults: UserDefaults
    /// Sink for a freshly-derived idle commute ETA → the home-screen widget.
    /// Defaults to the main-actor `NavigationStateManager` (which owns the
    /// no-op-while-navigating guard + the widget timeline reload). Injectable so
    /// tests assert the pushed ETA in isolation instead of racing the
    /// process-wide App Group defaults the shared singleton writes (parallel
    /// suites call `clearIdleCommuteETA`, stomping the shared key mid-assertion).
    private let idleETASink: @MainActor @Sendable (_ commuteName: String, _ destinationName: String, _ etaMinutes: Int) -> Void

    // MARK: Observable State

    /// Mirrors UNAuthorizationStatus for Settings UI.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init(
        modelContainer: ModelContainer,
        weatherService: CommuteWeatherService = CommuteWeatherService(),
        notificationCenter: CommuteNotificationCenter = .shared,
        directionsService: DirectionsService = DirectionsService(),
        locationProvider: @escaping @Sendable () -> CLLocationCoordinate2D? = { nil },
        defaults: UserDefaults = .standard,
        idleETASink: @escaping @MainActor @Sendable (String, String, Int) -> Void = {
            NavigationStateManager.shared.updateIdleCommuteETA(
                commuteName: $0, destinationName: $1, etaMinutes: $2
            )
        }
    ) {
        self.modelContainer = modelContainer
        self.weatherService = weatherService
        self.notificationCenter = notificationCenter
        self.directionsService = directionsService
        self.locationProvider = locationProvider
        self.defaults = defaults
        self.idleETASink = idleETASink
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
    ///
    /// `authorizationStatus` is an `@Observable` property SwiftUI reads on the
    /// main actor, but this method is nonisolated `async` and its callers
    /// (AppDelegate's launch Task, the Settings view's refresh) run on the
    /// cooperative pool. Hop the assignment onto the main actor so the
    /// Observation-tracked write never races a main-actor read.
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status = settings.authorizationStatus
        await MainActor.run { self.authorizationStatus = status }
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
            // No upcoming departures (commutes removed/deactivated, rules cleared).
            // Clear any previously submitted request so a stale task can't fire
            // around a now-defunct window and burn background budget on a no-op.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
            serviceLog.info("no learned/scheduled departures; cleared pending background refresh")
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

        // BGTask.setTaskCompleted must be called exactly once. The work Task and
        // the expirationHandler race to finish the same task, so guard completion
        // with an actor-isolated one-shot flag: whichever path runs first wins,
        // the other becomes a no-op. The actor serializes the check-and-set so the
        // two paths can never both call setTaskCompleted.
        let completion = BGTaskCompletionGuard()
        let work = Task {
            await runNotificationPass()
            await completion.complete(task, success: true)
        }
        task.expirationHandler = {
            // iOS gives BGAppRefreshTask only seconds; on expiration cancel the
            // in-flight pass (runNotificationPass honors Task.isCancelled and
            // short-circuits) and finish the task as a timeout.
            work.cancel()
            Task { await completion.complete(task, success: false) }
        }
    }

    /// One-shot guard so a BGTask is completed exactly once across the racing
    /// work-completion and expiration-handler paths. An actor serializes the
    /// `completed` check-and-set so the two paths can't both call setTaskCompleted.
    private actor BGTaskCompletionGuard {
        private var completed = false
        func complete(_ task: BGAppRefreshTask, success: Bool) {
            guard !completed else { return }
            completed = true
            task.setTaskCompleted(success: success)
        }
    }

    // MARK: - Model Snapshot (thread-safety boundary)

    /// A plain, `Sendable` snapshot of everything the async notification/ETA work
    /// needs from a `@Model Commute` (and its routes/trips). `@Model` objects are
    /// bound to the `ModelContext` that created them and are NOT `Sendable`; after
    /// an `await` the async function can resume on a different cooperative-pool
    /// thread, so touching the model (or its lazily-faulted relationships) there
    /// is a SwiftData thread-confinement violation. Every model property the
    /// post-`await` work reads is therefore extracted into this value struct
    /// synchronously on the context's executor BEFORE any suspension point, and
    /// only the snapshot crosses awaits.
    private struct CommuteSnapshot: Sendable {
        let id: UUID
        let name: String
        let notificationsEnabled: Bool
        let notificationLeadMinutes: Int
        let quietHoursStart: Int?
        let quietHoursEnd: Int?
        let direction: CommuteDirection
        let expectedDepartureHours: [Int]
        let fromLearnedHistory: Bool
        let destinationCoordinate: CLLocationCoordinate2D?
        let destinationName: String
        /// Preferred route's stored typical duration (seconds) for `direction`.
        let typicalDurationSeconds: TimeInterval?
    }

    /// Build a `CommuteSnapshot` by reading every needed `@Model` property while
    /// still pinned to the context's executor (called before any `await`). All
    /// direction resolution, learned/scheduled-hour analysis, destination lookup
    /// and preferred-route reads happen here so the async work never re-touches
    /// the model. Returns nil only when there is no usable departure window
    /// (no learned or scheduled hours) — NOT when notifications are disabled.
    ///
    /// The per-commute `notificationsEnabled` flag is captured into the snapshot
    /// (so the decision engine can skip the actual alert) but it does NOT gate
    /// the snapshot itself: the idle home-screen ETA widget reflects the next
    /// commute regardless of its notification preference (see
    /// `refreshIdleCommuteETA`). Gating the snapshot here would have frozen the
    /// widget for any commute whose leave-early alerts the user turned off.
    private func snapshot(for commute: Commute, allTrips: [CommuteTrip], now: Date) -> CommuteSnapshot? {
        // Direction for this window: schedule rules first, then next-scheduled.
        let direction = CommuteDirectionResolver.scheduledDirection(commute: commute, now: now)
            ?? CommuteDirectionResolver.nextScheduledDirection(commute: commute, now: now)
            ?? .originToDestination

        let learned = Self.learnedDepartureHours(commute: commute, trips: allTrips, now: now)
        let scheduled = Self.scheduledDepartureHours(commute: commute, direction: direction, now: now)
        let expectedHours = learned.isEmpty ? scheduled : learned

        let (destCoord, destName) = destination(for: commute, direction: direction)

        return CommuteSnapshot(
            id: commute.id,
            name: commute.name,
            notificationsEnabled: commute.notificationsEnabled,
            notificationLeadMinutes: commute.notificationLeadMinutes,
            quietHoursStart: commute.quietHoursStart,
            quietHoursEnd: commute.quietHoursEnd,
            direction: direction,
            expectedDepartureHours: expectedHours,
            fromLearnedHistory: !learned.isEmpty,
            destinationCoordinate: destCoord,
            destinationName: destName,
            typicalDurationSeconds: commute.preferredRoute(for: direction)?.typicalDurationSeconds
        )
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

        // The widget shows ONE upcoming commute, so only the commute owning the
        // next departure window should push its ETA to the idle widget — every
        // other commute in this pass evaluates notifications but leaves the
        // widget alone, so the last commute in the loop can't arbitrarily win.
        let widgetCommuteID = nextDepartureCommuteID(commutes: commutes, trips: allTrips, now: now)

        // Snapshot every commute's model fields synchronously (still on the
        // context's executor) BEFORE any await — the @Model objects must not be
        // touched once the async ETA/weather work suspends and resumes on another
        // thread. Only Sendable snapshots cross the awaits below.
        let snapshots: [CommuteSnapshot] = commutes.compactMap {
            snapshot(for: $0, allTrips: allTrips, now: now)
        }

        for snapshot in snapshots {
            // Honor cooperative cancellation: when the BGTask expiration handler
            // fires it cancels this work, and the constrained background window is
            // already spent — stop dispatching rather than running every remaining
            // commute's ETA/weather work (which would be discarded and could land
            // an alert after the task is reported timed-out).
            if Task.isCancelled { return }
            await evaluateAndDispatch(
                snapshot: snapshot,
                now: now,
                pushIdleETA: snapshot.id == widgetCommuteID
            )
        }
    }

    // MARK: - Idle Widget Refresh (pre-drive)

    /// Lightweight refresh of the home-screen ETA widget for the next upcoming
    /// commute, without running the full notification pass (no alerts dispatched).
    /// Reuses the same ETA computation the background pass and the commute-ETA
    /// intent use — the live MKDirections ETA when a location fix is available,
    /// else the preferred route's stored typical duration — so opening/closing
    /// the app keeps the widget fresh before the first drive. No-op while a live
    /// nav session is active (NavigationStateManager also guards this) so it can't
    /// clobber a live ETA.
    func refreshIdleCommuteETA(now: Date = Date()) async {
        // Deliberately NOT gated on `globallyEnabled`: the home-screen commute-ETA
        // widget is a separate feature from smart-commute notifications. Turning
        // notifications off must not freeze the widget — it would then show
        // "No ETA yet" (or a stale value past the freshness window) forever. Only
        // the notification-specific paths (scheduleBackgroundRefresh /
        // runNotificationPass) honor that master toggle; the widget data refresh
        // does not. The no-op-while-navigating guard below still stands so this
        // can't clobber a live ETA.
        if await MainActor.run(body: { NavigationStateManager.shared.isNavigating }) { return }

        let context = ModelContext(modelContainer)
        let commutes: [Commute]
        do {
            commutes = try context.fetch(
                FetchDescriptor<Commute>(predicate: #Predicate { $0.isActive })
            )
        } catch {
            serviceLog.error("idle ETA: failed to fetch commutes: \(error.localizedDescription, privacy: .public)")
            return
        }
        let trips = (try? context.fetch(FetchDescriptor<CommuteTrip>())) ?? []

        // Snapshot the chosen commute's model fields synchronously, before the
        // ETA await below — the @Model must not be touched after the network
        // suspension resumes on another thread.
        guard let widgetCommuteID = nextDepartureCommuteID(commutes: commutes, trips: trips, now: now),
              let commute = commutes.first(where: { $0.id == widgetCommuteID }),
              let snapshot = snapshot(for: commute, allTrips: trips, now: now)
        else { return }

        // Live ETA only when a fix exists; otherwise fall back to typical so the
        // widget still shows something useful before the first drive.
        var etaSeconds: TimeInterval?
        if let here = locationProvider(), let dest = snapshot.destinationCoordinate {
            do {
                etaSeconds = try await directionsService.fetchDirectETA(from: here, to: dest)
            } catch {
                serviceLog.notice("idle ETA fetch failed for \(snapshot.name, privacy: .public); using typical duration: \(error.localizedDescription, privacy: .public)")
            }
        }

        await pushIdleCommuteETA(
            commuteName: snapshot.name,
            destinationName: snapshot.destinationName,
            etaSeconds: etaSeconds ?? snapshot.typicalDurationSeconds
        )
    }

    /// Evaluate a single commute from its `Sendable` snapshot. The snapshot was
    /// built synchronously on the context's executor before this is called, so no
    /// `@Model` object is touched here — all reads cross the `await` boundaries
    /// safely.
    private func evaluateAndDispatch(snapshot: CommuteSnapshot, now: Date, pushIdleETA: Bool) async {
        // ETA: requires both a current location and a destination coordinate.
        // A failed fetch (network/invalid coords) must not be silently swallowed
        // — log it so a suppressed notification is diagnosable. The decision
        // engine falls back to the typical duration below when currentETA is nil.
        var currentETA: TimeInterval?
        if let here = locationProvider(), let dest = snapshot.destinationCoordinate {
            do {
                currentETA = try await directionsService.fetchDirectETA(from: here, to: dest)
            } catch {
                serviceLog.notice("ETA fetch failed for \(snapshot.name, privacy: .public); falling back to typical duration: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Typical baseline: preferred route's stored typical duration.
        let typical = snapshot.typicalDurationSeconds

        // Pre-drive widget: this commute owns the next departure window, so push
        // its freshly-computed ETA to the idle home-screen widget. Reuse exactly
        // the ETA this pass already derived — the live MKDirections value when
        // available, else the route's stored typical duration — so no extra
        // route/network call happens just for the widget. NavigationStateManager
        // no-ops the write while a live nav session is active and reloads the
        // widget timeline itself.
        if pushIdleETA {
            await pushIdleCommuteETA(
                commuteName: snapshot.name,
                destinationName: snapshot.destinationName,
                etaSeconds: currentETA ?? typical
            )
        }

        // Weather for the destination (degrades to .unavailable gracefully).
        let weather: WeatherCondition
        if let dest = snapshot.destinationCoordinate {
            weather = await weatherService.condition(for: dest)
        } else {
            weather = .unavailable
        }

        let input = CommuteNotificationDecisionEngine.Input(
            notificationsEnabled: snapshot.notificationsEnabled,
            globallyEnabled: globallyEnabled,
            leadMinutes: snapshot.notificationLeadMinutes,
            quietHoursStart: snapshot.quietHoursStart,
            quietHoursEnd: snapshot.quietHoursEnd,
            expectedDepartureHours: snapshot.expectedDepartureHours,
            fromLearnedHistory: snapshot.fromLearnedHistory,
            currentETA: currentETA,
            typicalDuration: typical,
            weather: weather,
            weatherSensitivity: weatherSensitivity,
            lastNotificationTime: notificationCenter.lastNotificationTime(commuteId: snapshot.id),
            now: now,
            destinationName: snapshot.destinationName
        )

        // The ETA + WeatherKit awaits above can outlast the BGTask budget; if the
        // expiration handler cancelled this pass mid-flight, don't dispatch an
        // alert for a run the scheduler has already reported as timed-out.
        if Task.isCancelled { return }

        let decision = CommuteNotificationDecisionEngine.evaluate(input)
        switch decision {
        case .skip(let reason):
            serviceLog.debug("skip \(snapshot.name, privacy: .public): \(reason, privacy: .public)")
        case .notify(let message, let actionType, let leadMinutes):
            let title = Self.title(for: actionType, leadMinutes: leadMinutes)
            let deepLink = CommuteNotificationCenter.startCommuteDeepLink(
                commuteId: snapshot.id, direction: snapshot.direction
            )
            // Fire roughly now — the background pass already runs close to the
            // departure window. A tiny delay keeps the trigger valid.
            await notificationCenter.scheduleAlert(
                commuteId: snapshot.id,
                direction: snapshot.direction,
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
    /// fallback). The window start hour is the expected departure, but only on
    /// days the user actually configured for that direction — a weekday-only
    /// commute returns nothing on Saturday/Sunday so the engine can't fire a
    /// "leave early" alert (or waste a background wakeup) on an excluded day.
    static func scheduledDepartureHours(
        commute: Commute,
        direction: CommuteDirection,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Int] {
        let weekday = calendar.component(.weekday, from: now)
        switch direction {
        case .originToDestination:
            guard scheduleActive(days: commute.scheduleToDestDays, on: weekday) else { return [] }
            return commute.scheduleToDestStartHour.map { [$0] } ?? []
        case .destinationToOrigin:
            guard scheduleActive(days: commute.scheduleToOriginDays, on: weekday) else { return [] }
            return commute.scheduleToOriginStartHour.map { [$0] } ?? []
        }
    }

    /// Whether a direction's day-of-week rule is active on `weekday` (Sun=1..Sat=7).
    /// Mirrors `CommuteDirectionResolver`'s `days.contains(currentDay)` test. A nil
    /// or empty days string means "no day restriction configured" — treat every
    /// day as active so a schedule with only start hours set still works.
    static func scheduleActive(days: String?, on weekday: Int) -> Bool {
        guard let days, !days.isEmpty else { return true }
        let set = Set(days.split(separator: ",").compactMap { Int($0) })
        guard !set.isEmpty else { return true }
        return set.contains(weekday)
    }

    // MARK: - Helpers

    /// Earliest upcoming departure Date for a single commute (learned or
    /// scheduled rules over the next 7 days). nil when nothing is known.
    ///
    /// Deliberately NOT gated on `notificationsEnabled`: this is the
    /// notifications-agnostic departure primitive the idle widget selection
    /// (`nextDepartureCommuteID`) relies on so the home-screen ETA reflects the
    /// next commute even when its leave-early alerts are off. The
    /// notification-scheduling path (`nextDepartureDate`) filters out
    /// notification-disabled commutes itself before calling this.
    private func nextDeparture(for commute: Commute, trips: [CommuteTrip], now: Date, calendar cal: Calendar) -> Date? {
        var best: Date?
        for dayOffset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            // Learned hours are already filtered to this day's day-of-week.
            // Schedule-rule hours must honor each direction's configured days so a
            // weekday-only commute never schedules a wakeup on the weekend.
            let learned = Self.learnedDepartureHours(commute: commute, trips: trips, now: day, calendar: cal)
            let toDest = Self.scheduledDepartureHours(
                commute: commute, direction: .originToDestination, now: day, calendar: cal
            )
            let toOrigin = Self.scheduledDepartureHours(
                commute: commute, direction: .destinationToOrigin, now: day, calendar: cal
            )
            let hours = Set(learned + toDest + toOrigin)
            for hour in hours {
                guard let candidate = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day),
                      candidate > now else { continue }
                best = best.map { min($0, candidate) } ?? candidate
            }
        }
        return best
    }

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
        for commute in commutes {
            // This drives BGAppRefreshTask scheduling for notifications, so skip
            // commutes whose alerts are off — no point burning a background wakeup
            // for a commute that will never notify. (The notifications-agnostic
            // widget path uses `nextDeparture` directly and does not filter.)
            guard commute.notificationsEnabled else { continue }
            guard let candidate = nextDeparture(for: commute, trips: trips, now: now, calendar: cal) else { continue }
            best = best.map { min($0, candidate) } ?? candidate
        }
        return best
    }

    /// The id of the active commute whose next departure window comes soonest —
    /// the one whose ETA the idle pre-drive widget should reflect. nil when no
    /// upcoming departure is known across the given commutes. Internal (not
    /// private) so the next-commute selection can be unit-tested without racing
    /// on the shared App Group widget defaults.
    func nextDepartureCommuteID(commutes: [Commute], trips: [CommuteTrip], now: Date) -> UUID? {
        let cal = Calendar.current
        var bestDate: Date?
        var bestID: UUID?
        for commute in commutes {
            guard let candidate = nextDeparture(for: commute, trips: trips, now: now, calendar: cal) else { continue }
            if bestDate == nil || candidate < bestDate! {
                bestDate = candidate
                bestID = commute.id
            }
        }
        return bestID
    }

    /// Hand a freshly-derived commute ETA to the idle home-screen widget,
    /// converting the route duration (seconds) to whole minutes the same way the
    /// commute-ETA intent does. NavigationStateManager is main-actor isolated and
    /// owns the no-op-while-navigating guard plus the widget timeline reload.
    private func pushIdleCommuteETA(commuteName: String, destinationName: String, etaSeconds: TimeInterval?) async {
        guard let etaSeconds, etaSeconds > 0 else { return }
        let minutes = max(1, Int((etaSeconds / 60).rounded()))
        await MainActor.run {
            self.idleETASink(commuteName, destinationName, minutes)
        }
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
