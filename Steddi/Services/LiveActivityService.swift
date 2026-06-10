import ActivityKit
import Foundation

/// Manages the navigation Live Activity lifecycle.
/// Starts activity when nav begins, updates on each engine tick, ends on arrival or stop.
@MainActor
final class LiveActivityService {
    static let shared = LiveActivityService()

    private var currentActivity: Activity<NavigationAttributes>?

    private init() {}

    /// Start a Live Activity for the current navigation session.
    func startActivity(destinationName: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = NavigationAttributes(destinationName: destinationName)
        let initialState = NavigationAttributes.ContentState(
            instruction: "Starting navigation...",
            stepDistance: "",
            etaMinutes: 0,
            distanceRemaining: "",
            arrivalTime: "",
            maneuverSymbol: "arrow.up",
            speedMph: 0,
            roadName: ""
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
            roadName: engine.roadName
        )

        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(600))

        Task {
            await activity.update(content)
        }
    }

    /// End the Live Activity.
    func endActivity() {
        guard let activity = currentActivity else { return }

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
            currentActivity = nil
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
