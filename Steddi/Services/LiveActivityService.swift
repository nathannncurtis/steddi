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

    private init() {}

    /// Start a Live Activity for the current navigation session.
    func startActivity(destinationName: String, tripContext: TripActivityContext? = nil) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        self.tripContext = tripContext
        let attributes = NavigationAttributes(destinationName: destinationName)
        let initialState = NavigationAttributes.ContentState(
            instruction: "Starting navigation...",
            stepDistance: "",
            etaMinutes: 0,
            distanceRemaining: "",
            arrivalTime: "",
            maneuverSymbol: "arrow.up",
            speedMph: 0,
            roadName: "",
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
    func updateActivity(engine: NavigationEngine) {
        guard let activity = currentActivity else { return }

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

        // Guard against updating an activity the system has already torn down
        // (permission revoked, dismissed, or ended): a stale handle reports a
        // non-active state. Surface it instead of silently no-oping.
        Task {
            guard activity.activityState == .active else {
                print("[STEDDI] Skipping Live Activity update — activity not active (state: \(activity.activityState))")
                return
            }
            await activity.update(content)
        }
    }

    /// End the Live Activity.
    ///
    /// Claims `currentActivity` atomically on the MainActor (reads then nils it
    /// before spawning the async end) so a second concurrent call's guard fails
    /// and can't double-end / clobber the handle. All end paths
    /// (endActivity, endActivityImmediately, the auto-end on arrival) share this
    /// claim-then-act discipline.
    func endActivity() {
        tripContext = nil
        // Atomic claim: read + clear on the MainActor before any await.
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

        Task {
            await activity.end(content, dismissalPolicy: .after(.now + 30))
        }
    }

    /// End the Live Activity right now — termination path for
    /// applicationWillTerminate / sceneDidDisconnect, where the normal async
    /// lifecycle never gets a chance to run before the process dies.
    /// Blocks the caller briefly (bounded at 2s) so the end request lands;
    /// without it the activity lingers on the Lock Screen as a zombie.
    func endActivityImmediately() {
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
        currentActivity = nil
    }

    /// Kill any orphaned activities from previous sessions.
    func cleanupOrphanedActivities() {
        for activity in Activity<NavigationAttributes>.activities {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        currentActivity = nil
    }
}
