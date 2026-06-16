import AppIntents
import CoreLocation
import SwiftData

/// "Hey Siri, how's my drive to work?" — returns the current ETA without opening the app.
struct CheckCommuteETAIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Commute ETA"
    static var description: IntentDescription = "Check how long your commute will take right now."

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        // Read commutes from the shared App Group store (read-only), falling
        // back to the legacy store if the app hasn't migrated yet.
        let container: ModelContainer
        do {
            container = try ModelStoreLocator.makeReadOnlySharedContainer()
        } catch ModelStoreLocator.StoreError.sharedStoreUnavailable {
            // No store on disk yet — the user genuinely has no commutes.
            return respond("You haven't set up any commutes yet.")
        } catch {
            // The store exists but the read-only container couldn't OPEN it. The
            // migration-needed case surfaces here (the read-only store can't
            // migrate), so steer the user to open the app — the same copy the
            // fetch path uses — instead of falsely claiming they have no commutes.
            return respond("I couldn't read your commutes right now. Open Steddi once to finish updating, then try again.")
        }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Commute>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        // Guard the fetch the same way the open is guarded: a read-only
        // container can open fine but throw at fetch time when the on-disk
        // schema is behind (SwiftData defers the migration check, and a
        // read-only store can't migrate). Distinguish that failure from a
        // genuinely empty store so we don't tell a user with commutes that they
        // have none — steer them to open the app (which performs the migration).
        let commutes: [Commute]
        do {
            commutes = try context.fetch(descriptor)
        } catch {
            return respond("I couldn't read your commutes right now. Open Steddi once to finish updating, then try again.")
        }

        guard let commute = commutes.first else {
            return respond("You haven't set up any commutes yet.")
        }
        guard commute.origin != nil, commute.destination != nil else {
            return respond("Your commute isn't fully set up yet. Open Steddi to add its locations.")
        }

        // Extract everything the async ETA work needs from the `@Model Commute`
        // (and its routes/locations) into a `Sendable` snapshot NOW, while we are
        // still synchronously on the `ModelContext`'s executor. `@Model` objects
        // and their lazily-faulted relationships are bound to that executor and
        // are NOT `Sendable`; after the `await`s below the function can resume on
        // a different cooperative-pool thread, so any post-`await` access to the
        // model (coordinates, names, the `routes` relationship via
        // `preferredRoute`) would be a SwiftData thread-confinement violation.
        // This mirrors `CommuteNotificationService.CommuteSnapshot`. Direction
        // depends on the post-`await` location fix, so we capture BOTH directions'
        // endpoint + typical-duration data up front and select after resolving.
        guard let snapshot = CommuteETASnapshot(commute: commute) else {
            return respond("Your commute isn't fully set up yet. Open Steddi to add its locations.")
        }

        // Resolve direction: proximity when we have a location fix, then the
        // active schedule window, then the next scheduled window, defaulting
        // to heading out (origin → destination).
        //
        // A cold `CLLocationManager().location` is virtually always nil here:
        // intents run without the app's running location service, so the
        // property was never populated. Request a proper one-shot fix instead,
        // failing gracefully (nil) on denial/timeout so direction falls back to
        // the schedule. After this await we only touch the value snapshot.
        let currentLocation = await OneShotLocation.current()
        let direction = Self.resolveDirection(snapshot: snapshot, currentLocation: currentLocation)

        let endpoints = snapshot.endpoints(for: direction)
        let startCoordinate = currentLocation?.coordinate ?? endpoints.startCoordinate

        do {
            let eta = try await DirectionsService().fetchDirectETA(
                from: startCoordinate,
                to: endpoints.destinationCoordinate
            )
            let minutes = max(1, Int((eta / 60).rounded()))
            return respond("Your drive to \(endpoints.destinationName) is about \(minutes) minutes right now.")
        } catch {
            // Live traffic unavailable — fall back to the route's typical time.
            if let typical = endpoints.typicalDurationSeconds, typical > 0 {
                let minutes = max(1, Int((typical / 60).rounded()))
                return respond("I couldn't get live traffic, but your drive to \(endpoints.destinationName) is typically about \(minutes) minutes.")
            }
            return respond("I couldn't calculate your commute ETA right now. Open Steddi for details.")
        }
    }

    // MARK: - Private

    private func respond(_ message: String) -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        .result(value: message, dialog: IntentDialog("\(message)"))
    }

    /// Resolve the commute direction from the `Sendable` snapshot and an optional
    /// post-`await` location fix. Pure value logic (no `@Model` access) so it is
    /// safe to call after a suspension point and is unit-testable in isolation.
    /// Mirrors `resolveDirection(commute:currentLocation:)`'s old precedence:
    /// proximity → active schedule window → next scheduled window → to-destination.
    static func resolveDirection(
        snapshot: CommuteETASnapshot,
        currentLocation: CLLocation?,
        now: Date = Date()
    ) -> CommuteDirection {
        if let currentLocation,
           let proximity = snapshot.proximityDirection(currentLocation: currentLocation) {
            return proximity
        }
        if let scheduled = snapshot.schedule.scheduledDirection(now: now) {
            return scheduled
        }
        if let next = snapshot.schedule.nextScheduledDirection(now: now) {
            return next
        }
        return .originToDestination
    }
}

/// A plain, `Sendable` snapshot of everything `CheckCommuteETAIntent` needs from
/// a `@Model Commute` (its endpoints, schedule, and both directions' preferred
/// route durations). Built synchronously on the `ModelContext`'s executor before
/// any `await`, so the async ETA work never re-touches the non-`Sendable` model
/// or its lazily-faulted relationships off a resumed cooperative-pool thread.
/// Mirrors `CommuteNotificationService.CommuteSnapshot`.
struct CommuteETASnapshot: Sendable {
    /// Captured schedule rules (proximity-independent direction resolution).
    let schedule: CommuteScheduleSnapshot
    let originCoordinate: CLLocationCoordinate2D
    let destinationCoordinate: CLLocationCoordinate2D
    let originName: String
    let destinationName: String
    /// Preferred-route typical duration (seconds) heading origin → destination.
    let toDestinationTypicalSeconds: TimeInterval?
    /// Preferred-route typical duration (seconds) heading destination → origin.
    let toOriginTypicalSeconds: TimeInterval?

    /// The resolved start/destination endpoints for a given travel direction.
    struct DirectionEndpoints {
        let startCoordinate: CLLocationCoordinate2D
        let destinationCoordinate: CLLocationCoordinate2D
        let destinationName: String
        let typicalDurationSeconds: TimeInterval?
    }

    /// Build the snapshot by reading every needed `@Model` property while still
    /// pinned to the context's executor. Returns nil if the commute has no
    /// origin/destination. MUST be called before any `await`.
    init?(commute: Commute) {
        guard let origin = commute.origin, let destination = commute.destination else {
            return nil
        }
        self.schedule = CommuteScheduleSnapshot(commute: commute)
        self.originCoordinate = origin.coordinate
        self.destinationCoordinate = destination.coordinate
        self.originName = origin.name
        self.destinationName = destination.name
        self.toDestinationTypicalSeconds = commute.preferredRoute(for: .originToDestination)?.typicalDurationSeconds
        self.toOriginTypicalSeconds = commute.preferredRoute(for: .destinationToOrigin)?.typicalDurationSeconds
    }

    /// Resolve direction by proximity to an endpoint, returning nil when the
    /// fix isn't clearly at exactly one endpoint. Mirrors
    /// `CommuteDirectionResolver.resolve`'s proximity branch over value copies.
    func proximityDirection(currentLocation: CLLocation) -> CommuteDirection? {
        let proximityRadius: Double = 152
        let originLoc = CLLocation(latitude: originCoordinate.latitude, longitude: originCoordinate.longitude)
        let destLoc = CLLocation(latitude: destinationCoordinate.latitude, longitude: destinationCoordinate.longitude)
        let distToOrigin = currentLocation.distance(from: originLoc)
        let distToDest = currentLocation.distance(from: destLoc)
        if distToOrigin < proximityRadius && distToDest >= proximityRadius {
            return .originToDestination
        }
        if distToDest < proximityRadius && distToOrigin >= proximityRadius {
            return .destinationToOrigin
        }
        return nil
    }

    /// Endpoints (start, destination, name, typical duration) for a direction.
    func endpoints(for direction: CommuteDirection) -> DirectionEndpoints {
        switch direction {
        case .originToDestination:
            return DirectionEndpoints(
                startCoordinate: originCoordinate,
                destinationCoordinate: destinationCoordinate,
                destinationName: destinationName,
                typicalDurationSeconds: toDestinationTypicalSeconds
            )
        case .destinationToOrigin:
            return DirectionEndpoints(
                startCoordinate: destinationCoordinate,
                destinationCoordinate: originCoordinate,
                destinationName: originName,
                typicalDurationSeconds: toOriginTypicalSeconds
            )
        }
    }
}

/// `Sendable` copy of a commute's schedule rules. Direction resolution by
/// schedule is pure logic over these captured strings/hours, so it runs safely
/// after an `await`. Mirrors `CommuteDirectionResolver.scheduledDirection` /
/// `nextScheduledDirection`, which read these same fields off the `@Model`.
struct CommuteScheduleSnapshot: Sendable {
    let toDestDays: String?
    let toDestStartHour: Int?
    let toDestEndHour: Int?
    let toOriginDays: String?
    let toOriginStartHour: Int?
    let toOriginEndHour: Int?

    init(commute: Commute) {
        self.toDestDays = commute.scheduleToDestDays
        self.toDestStartHour = commute.scheduleToDestStartHour
        self.toDestEndHour = commute.scheduleToDestEndHour
        self.toOriginDays = commute.scheduleToOriginDays
        self.toOriginStartHour = commute.scheduleToOriginStartHour
        self.toOriginEndHour = commute.scheduleToOriginEndHour
    }

    /// Direction whose schedule window is active at `now`, else nil.
    /// Value-copy mirror of `CommuteDirectionResolver.scheduledDirection`.
    ///
    /// Delegates the window test to the canonical
    /// `CommuteDirectionResolver.windowActive` (a same-module static over plain
    /// values) so the Siri path and the in-app path can never diverge. The
    /// previous in-line copy gated BOTH portions of a window on
    /// `days.contains(currentDay)`, which mis-resolved wrapping windows that span
    /// midnight (start > end, e.g. 22:00–06:00): `windowActive` attributes the
    /// morning portion (hour < end) to the PREVIOUS weekday, so a Monday-only
    /// 22→6 schedule is correctly active at Tuesday 02:00.
    func scheduledDirection(now: Date = Date()) -> CommuteDirection? {
        let cal = Calendar.current
        let currentDay = cal.component(.weekday, from: now)
        let currentHour = cal.component(.hour, from: now)

        if let daysStr = toDestDays, let startHour = toDestStartHour, let endHour = toDestEndHour {
            let days = Set(daysStr.split(separator: ",").compactMap { Int($0) })
            if CommuteDirectionResolver.windowActive(
                day: currentDay, hour: currentHour, days: days, start: startHour, end: endHour
            ) {
                return .originToDestination
            }
        }
        if let daysStr = toOriginDays, let startHour = toOriginStartHour, let endHour = toOriginEndHour {
            let days = Set(daysStr.split(separator: ",").compactMap { Int($0) })
            if CommuteDirectionResolver.windowActive(
                day: currentDay, hour: currentHour, days: days, start: startHour, end: endHour
            ) {
                return .destinationToOrigin
            }
        }
        return nil
    }

    /// Direction of the next upcoming schedule window after `now`, else nil.
    /// Value-copy mirror of `CommuteDirectionResolver.nextScheduledDirection`.
    func nextScheduledDirection(now: Date = Date()) -> CommuteDirection? {
        let cal = Calendar.current
        let rules: [(days: String?, startHour: Int?, direction: CommuteDirection)] = [
            (toDestDays, toDestStartHour, .originToDestination),
            (toOriginDays, toOriginStartHour, .destinationToOrigin)
        ]

        var best: (start: Date, direction: CommuteDirection)?

        for rule in rules {
            guard let daysStr = rule.days, let startHour = rule.startHour else { continue }
            let days = Set(daysStr.split(separator: ",").compactMap { Int($0) })
            guard !days.isEmpty else { continue }

            for dayOffset in 0...7 {
                guard let day = cal.date(byAdding: .day, value: dayOffset, to: now),
                      days.contains(cal.component(.weekday, from: day)),
                      let start = cal.date(bySettingHour: startHour, minute: 0, second: 0, of: day),
                      start > now else { continue }
                if let current = best {
                    if start < current.start { best = (start, rule.direction) }
                } else {
                    best = (start, rule.direction)
                }
                break
            }
        }
        return best?.direction
    }
}
