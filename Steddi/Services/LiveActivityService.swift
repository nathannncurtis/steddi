import ActivityKit
import Foundation

/// Trip context attached to a navigation Live Activity — drives the
/// "Leg 2 of 5" presentation for multi-stop trips.
struct TripActivityContext {
    let tripName: String
    let legIndex: Int    // 1-based
    let totalLegs: Int
}

/// Manages the navigation Live Activity lifecycle.
/// Starts activity when nav begins, updates on each engine tick, ends on arrival or stop.
@MainActor
final class LiveActivityService {
    static let shared = LiveActivityService()

    private var currentActivity: Activity<NavigationAttributes>?
    /// Trip context for the current session — folded into every update.
    private var tripContext: TripActivityContext?

    /// Tail of the serialized ActivityKit-mutation chain. Every update/end is
    /// appended here and awaits the previous link before touching the activity,
    /// so the out-of-process ActivityKit calls happen in strict submission order
    /// — an update can never land *after* a later end and resurrect a just-ended
    /// activity. Reset per session in `startActivity`.
    private var lifecycleTail: Task<Void, Never>?

    /// Set once this session's activity has been ended. Any update enqueued after
    /// the end sees this and drops, so a late tick can't re-push an active
    /// ContentState onto an activity that's already dismissing. Reset per session.
    /// `private(set)` so tests can observe the latch (writes stay internal).
    private(set) var sessionEnded = false

    private init() {}

    /// Append an ActivityKit mutation to the serial lifecycle chain. Each op runs
    /// on the MainActor and awaits the prior op's completion, so update/end ordering
    /// matches submission order regardless of the underlying ActivityKit await
    /// latencies. State reads/writes (`currentActivity`, `sessionEnded`) inside
    /// `op` are MainActor-isolated, so they observe the effects of earlier links.
    private func enqueueLifecycle(_ op: @escaping @MainActor () async -> Void) {
        let previous = lifecycleTail
        lifecycleTail = Task { @MainActor in
            await previous?.value
            await op()
        }
    }

    /// Start a Live Activity for the current navigation session.
    ///
    /// `engine` seeds the initial ContentState from the route's real estimate
    /// (`originalExpectedTravelTime` / `totalRouteDistance`, both set by
    /// `startNavigation` before this is called) so the Lock Screen / Dynamic Island
    /// never flash "0 min" / "0m" for the first few seconds until the first update
    /// tick lands. Pass `nil` only if no engine estimate exists yet.
    func startActivity(
        destinationName: String,
        engine: NavigationEngine? = nil,
        tripContext: TripActivityContext? = nil
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        self.tripContext = tripContext
        // Fresh session — clear the prior session's end latch so updates flow.
        self.sessionEnded = false

        // Mirror the user's chosen accent into the shared App Group so the Live
        // Activity (a separate extension target that can't see SteddiTheme) can
        // tint its maneuver glyph / trip-leg label to match the in-app HUD
        // instead of a hardcoded lavender. Written at session start, so the
        // Activity reads the accent that's current for this drive. The accent
        // lives in UserDefaults.standard (@AppStorage), which the extension
        // can't read — only the App Group is shared.
        UserDefaults(suiteName: "group.to.nathancurtis.steddi")?.set(
            SteddiTheme.currentAccentOption.rawValue,
            forKey: "accentColor"
        )

        let attributes = NavigationAttributes(destinationName: destinationName)

        // Seed from the route's expected travel time / total distance so the very
        // first render shows a real ETA. The location-driven fields aren't known
        // yet, so the engine's own `etaMinutes`/`distanceRemaining` are 0 at start
        // — derive the seed straight from the route estimate instead.
        let seedEtaSeconds = engine?.originalExpectedTravelTime ?? 0
        let seedDistanceMeters = engine?.totalRouteDistance ?? 0
        let seedEtaMinutes = seedEtaSeconds > 0 ? max(1, Int((seedEtaSeconds / 60).rounded())) : 0
        let seedDistance = seedDistanceMeters > 0
            ? NavigationEngine.formatDistance(seedDistanceMeters) : ""
        let seedArrival = seedEtaSeconds > 0
            ? NavigationEngine.formatArrivalTime(seedEtaSeconds) : ""

        let initialState = NavigationAttributes.ContentState(
            instruction: engine?.instruction.isEmpty == false
                ? engine!.instruction : "Starting navigation...",
            stepDistance: engine?.stepDistance ?? "",
            etaMinutes: seedEtaMinutes,
            distanceRemaining: seedDistance,
            arrivalTime: seedArrival,
            maneuverSymbol: engine?.maneuverType ?? "arrow.up",
            speedMph: 0,
            roadName: engine?.roadName ?? "",
            tripName: tripContext?.tripName,
            legIndex: tripContext?.legIndex,
            totalLegs: tripContext?.totalLegs
        )

        let content = ActivityContent(state: initialState, staleDate: Date().addingTimeInterval(600))

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            print("[STEDDI] Failed to start Live Activity: \(error)")
        }
    }

    /// Update the Live Activity with current navigation state.
    ///
    /// Enqueued on the serial lifecycle chain so it can never apply after a
    /// subsequent `endActivity` and resurrect a just-ended activity: by the time
    /// this link runs, an earlier-submitted end has completed and cleared
    /// `currentActivity` / set `sessionEnded`, so the guards below drop the update.
    func updateActivity(engine: NavigationEngine) {
        guard currentActivity != nil, !sessionEnded else { return }

        let state = NavigationAttributes.ContentState(
            instruction: engine.instruction,
            stepDistance: engine.stepDistance,
            etaMinutes: engine.etaMinutes,
            distanceRemaining: engine.distanceRemaining,
            arrivalTime: engine.arrivalTime,
            maneuverSymbol: engine.maneuverType,
            speedMph: Int(engine.currentSpeedMph),
            roadName: engine.roadName,
            tripName: tripContext?.tripName,
            legIndex: tripContext?.legIndex,
            totalLegs: tripContext?.totalLegs
        )

        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(600))

        enqueueLifecycle { [weak self] in
            guard let self else { return }
            // Re-resolve the live handle now that prior links (incl. any end) have
            // run. If the session ended or the handle was cleared, drop the update.
            guard !self.sessionEnded, let activity = self.currentActivity else {
                print("[STEDDI] Skipping Live Activity update — session ended or no active activity")
                return
            }
            // Guard against updating an activity the system has already torn down
            // (permission revoked, dismissed, or ended): a stale handle reports a
            // non-active state. Surface it instead of silently no-oping.
            guard activity.activityState == .active else {
                print("[STEDDI] Skipping Live Activity update — activity not active (state: \(activity.activityState))")
                return
            }
            await activity.update(content)
        }
    }

    /// End the Live Activity.
    ///
    /// Claims `currentActivity` atomically on the MainActor (reads, sets the
    /// `sessionEnded` latch, then nils it before enqueuing the async end) so a
    /// second concurrent call's guard fails and can't double-end / clobber the
    /// handle. All end paths (endActivity, endActivityImmediately, the auto-end on
    /// arrival) share this claim-then-act discipline.
    ///
    /// The end is enqueued on the serial lifecycle chain alongside updates, so an
    /// in-flight update submitted on an earlier tick runs to completion BEFORE
    /// this end (preserving order), and any update submitted AFTER this end sees
    /// the cleared handle / `sessionEnded` latch and drops — closing the
    /// lost-update window where a late update could resurrect a just-ended activity.
    ///
    /// `immediate` removes the activity from the Lock Screen / Dynamic Island
    /// right away instead of letting it linger 30s. Pass `true` for a trip leg
    /// handoff — the next leg's activity starts almost immediately, so the
    /// finished leg must clear at once or two nav activities stack. Reserve the
    /// default 30s linger for a true final arrival, where a brief "You have
    /// arrived" glance is wanted and nothing replaces it.
    func endActivity(immediate: Bool = false) {
        tripContext = nil
        // Atomic claim: latch ended + read + clear on the MainActor before any
        // await. Latching here (not inside the async link) means a later update
        // enqueued after this call already sees `sessionEnded == true` and drops.
        sessionEnded = true
        guard let activity = currentActivity else { return }
        currentActivity = nil

        let finalState = NavigationAttributes.ContentState(
            instruction: "You have arrived",
            stepDistance: "",
            etaMinutes: 0,
            distanceRemaining: "",
            arrivalTime: "",
            maneuverSymbol: "flag.fill",
            speedMph: 0,
            roadName: ""
        )

        let content = ActivityContent(state: finalState, staleDate: nil)
        let policy: ActivityUIDismissalPolicy = immediate ? .immediate : .after(.now + 30)

        enqueueLifecycle {
            await activity.end(content, dismissalPolicy: policy)
        }
    }

    /// End any Live Activity without blocking the caller — for paths where the
    /// process keeps running (a routine `sceneDidDisconnect` scene reclaim), so
    /// the main thread is never stalled. Fire-and-forget: the end request is
    /// dispatched and the next launch's `cleanupOrphanedActivities()` backstops
    /// anything that didn't land. Use `endActivityImmediately()` only when the
    /// process is actually dying (applicationWillTerminate), where the blocking
    /// wait is justified to make the end request land before we're killed.
    func endActivityAsync() {
        let activities = Activity<NavigationAttributes>.activities
        guard !activities.isEmpty else { return }
        // Latch ended + clear the handle on the MainActor so a concurrent update
        // tick drops, then route the end through the serial chain so any update
        // already submitted this session is ordered before it.
        sessionEnded = true
        currentActivity = nil
        enqueueLifecycle {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// End the Live Activity right now — termination path for
    /// applicationWillTerminate, where the normal async lifecycle never gets a
    /// chance to run before the process dies. Blocks the caller briefly (bounded
    /// at 2s) so the end request lands; without it the activity lingers on the
    /// Lock Screen as a zombie. Do NOT use this on a routine scene reclaim where
    /// the process survives — use `endActivityAsync()` to avoid stalling the UI.
    func endActivityImmediately() {
        // Latch ended + clear so any racing update tick drops; the process is
        // dying, so we end synchronously below rather than via the async chain.
        sessionEnded = true
        currentActivity = nil
        let activities = Activity<NavigationAttributes>.activities
        guard !activities.isEmpty else { return }

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            semaphore.signal()
        }
        // Best-effort at process death: the system gives terminating apps only a
        // short grace window, so we cap the wait at 2s. A longer block risks the
        // watchdog killing us before the end request lands anyway; if it times
        // out the activity may briefly linger, which the next launch's
        // `cleanupOrphanedActivities` sweeps up. This is an inherent
        // termination-path tradeoff, not a fixable race.
        _ = semaphore.wait(timeout: .now() + 2)
    }

    /// Kill any orphaned activities from previous sessions. Runs at launch before
    /// any session starts; `startActivity` resets `sessionEnded`, so latching it
    /// here only ensures no stray update can sneak in before the next session.
    func cleanupOrphanedActivities() {
        sessionEnded = true
        currentActivity = nil
        for activity in Activity<NavigationAttributes>.activities {
            enqueueLifecycle {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - Test Seam

    // ActivityKit can't vend a real `Activity` in a unit test (no entitlement /
    // host), so these internal hooks exercise the exact serialization + end-latch
    // logic the production update/end paths use — the serial chain
    // (`enqueueLifecycle`) and the `sessionEnded` drop — over a recordable sink
    // instead of a live activity. They reproduce the end-then-late-update race:
    // an update submitted before an end stays ordered before it, and an update
    // submitted after the end is dropped (never resurrects the activity).

    #if DEBUG
    /// Reset to a "session in progress" baseline (an active, non-nil-ish handle is
    /// simulated by clearing the ended latch). Test-only.
    func resetForTesting() {
        sessionEnded = false
        lifecycleTail = nil
    }

    /// Simulate `updateActivity`'s ordering+drop discipline over a sink: the op is
    /// enqueued on the real serial chain and only records `marker` if the session
    /// hasn't ended by the time the link runs — mirroring the production guard.
    func enqueueSimulatedUpdateForTesting(_ marker: String, into sink: LifecycleRecorder) {
        guard !sessionEnded else { return }
        enqueueLifecycle { [weak self] in
            guard let self, !self.sessionEnded else { return }
            await sink.record(marker)
        }
    }

    /// Simulate `endActivity`'s latch-then-enqueue: latches the ended flag on the
    /// MainActor synchronously (so later updates drop), then records the end on the
    /// serial chain after any earlier-submitted updates.
    func enqueueSimulatedEndForTesting(_ marker: String, into sink: LifecycleRecorder) {
        sessionEnded = true
        enqueueLifecycle {
            await sink.record(marker)
        }
    }

    /// Await the serial chain draining so tests can assert the final recording.
    func drainLifecycleForTesting() async {
        await lifecycleTail?.value
    }
    #endif
}

#if DEBUG
/// Ordered, thread-safe sink for the LiveActivityService lifecycle test seam.
actor LifecycleRecorder {
    private(set) var applied: [String] = []
    func record(_ marker: String) { applied.append(marker) }
}
#endif
