import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - UpcomingStep Tests

@Suite("UpcomingStep")
struct UpcomingStepTests {

    @Test("Holds all required properties")
    func holdsProperties() {
        let step = UpcomingStep(
            instruction: "Turn left onto Main St",
            distance: "0.3 mi",
            maneuverSymbol: "arrow.turn.up.left",
            roadName: "Main St"
        )
        #expect(step.instruction == "Turn left onto Main St")
        #expect(step.distance == "0.3 mi")
        #expect(step.maneuverSymbol == "arrow.turn.up.left")
        #expect(step.roadName == "Main St")
    }

    @Test("Road name can be nil")
    func roadNameNil() {
        let step = UpcomingStep(
            instruction: "Continue straight",
            distance: "1.2 mi",
            maneuverSymbol: "arrow.up",
            roadName: nil
        )
        #expect(step.roadName == nil)
    }

    @Test("Each instance gets a unique ID")
    func uniqueIds() {
        let a = UpcomingStep(instruction: "A", distance: "1 mi", maneuverSymbol: "arrow.up", roadName: nil)
        let b = UpcomingStep(instruction: "A", distance: "1 mi", maneuverSymbol: "arrow.up", roadName: nil)
        #expect(a.id != b.id)
    }
}

// MARK: - Format Distance Tests

@Suite("formatDistance")
struct FormatDistanceTests {

    @Test("Very short distance shows feet")
    func veryShortFeet() {
        // 50 meters ≈ 164 ft
        let result = NavigationStateManager.formatDistance(50)
        #expect(result == "164 ft")
    }

    @Test("Zero meters shows 0 ft")
    func zeroMeters() {
        let result = NavigationStateManager.formatDistance(0)
        #expect(result == "0 ft")
    }

    @Test("Just below 160m threshold shows feet")
    func justBelow160m() {
        let result = NavigationStateManager.formatDistance(159)
        #expect(result.hasSuffix("ft"))
    }

    @Test("At 160m switches to miles")
    func at160mShowsMiles() {
        let result = NavigationStateManager.formatDistance(160)
        #expect(result.hasSuffix("mi"))
    }

    @Test("Medium distance shows one decimal mile")
    func mediumDistanceDecimalMile() {
        // 1609.34m = 1.0 miles
        let result = NavigationStateManager.formatDistance(1609.34)
        #expect(result == "1.0 mi")
    }

    @Test("Half mile shows 0.5 mi")
    func halfMile() {
        let result = NavigationStateManager.formatDistance(804.67)
        #expect(result == "0.5 mi")
    }

    @Test("Just under 10 miles shows one decimal")
    func justUnder10Miles() {
        // 9.9 miles in meters
        let result = NavigationStateManager.formatDistance(9.9 * 1609.34)
        #expect(result == "9.9 mi")
    }

    @Test("At 10 miles shows whole number")
    func at10MilesWholeNumber() {
        let result = NavigationStateManager.formatDistance(10 * 1609.34)
        #expect(result == "10 mi")
    }

    @Test("Large distance shows whole miles")
    func largeDistanceWholeMiles() {
        // 25 miles
        let result = NavigationStateManager.formatDistance(25 * 1609.34)
        #expect(result == "25 mi")
    }

    @Test("100 miles shows whole number")
    func hundredMiles() {
        let result = NavigationStateManager.formatDistance(100 * 1609.34)
        #expect(result == "100 mi")
    }
}

// MARK: - Format Arrival Time Tests

@Suite("formatArrivalTime")
struct FormatArrivalTimeTests {

    @Test("Returns h:mm a format")
    func returnsCorrectFormat() {
        let result = NavigationStateManager.formatArrivalTime(3600) // 1 hour from now
        // Should match pattern like "1:30 PM" or "12:00 AM"
        #expect(result.contains(try! Regex(#"\d{1,2}:\d{2} (AM|PM)"#)))
    }

    @Test("Zero seconds remaining gives current time")
    func zeroSecondsGivesNow() {
        let result = NavigationStateManager.formatArrivalTime(0)
        // Format current time the same way for comparison
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let expected = formatter.string(from: Date())
        #expect(result == expected)
    }

    @Test("Large duration produces valid time string")
    func largeDuration() {
        // 24 hours from now
        let result = NavigationStateManager.formatArrivalTime(86400)
        #expect(!result.isEmpty)
        #expect(result.contains(try! Regex(#"\d{1,2}:\d{2} (AM|PM)"#)))
    }
}

// MARK: - SF Symbol From Instruction Tests

@Suite("sfSymbolFromInstruction")
struct SFSymbolFromInstructionTests {

    @Test("Turn left returns arrow.turn.up.left")
    func turnLeft() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Turn left onto Main St") == "arrow.turn.up.left")
    }

    @Test("Turn right returns arrow.turn.up.right")
    func turnRight() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Turn right onto Broadway") == "arrow.turn.up.right")
    }

    @Test("Sharp left returns arrow.turn.up.left")
    func sharpLeft() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Make a sharp left") == "arrow.turn.up.left")
    }

    @Test("Sharp right returns arrow.turn.up.right")
    func sharpRight() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Make a sharp right") == "arrow.turn.up.right")
    }

    @Test("Slight left returns arrow.turn.up.left")
    func slightLeft() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Slight left onto I-10") == "arrow.turn.up.left")
    }

    @Test("Bear right returns arrow.turn.up.right")
    func bearRight() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Bear right onto US-60") == "arrow.turn.up.right")
    }

    @Test("U-turn returns arrow.uturn.down")
    func uTurn() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Make a U-turn") == "arrow.uturn.down")
    }

    @Test("Merge returns arrow.merge")
    func merge() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Merge onto I-15") == "arrow.merge")
    }

    @Test("Ramp left returns arrow.up.left")
    func rampLeft() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Take the ramp on the left") == "arrow.up.left")
    }

    @Test("Ramp right returns arrow.up.right")
    func rampRight() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Take the ramp") == "arrow.up.right")
    }

    @Test("Roundabout returns arrow.triangle.2.circlepath")
    func roundabout() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Enter the roundabout") == "arrow.triangle.2.circlepath")
    }

    @Test("Arrive returns flag.fill")
    func arrive() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Arrive at your destination") == "flag.fill")
    }

    @Test("Depart returns location.fill")
    func depart() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Depart south on Main St") == "location.fill")
    }

    @Test("Continue straight returns arrow.up")
    func continueStraight() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Continue on Main St") == "arrow.up")
    }

    @Test("Unknown instruction returns arrow.up")
    func unknownInstruction() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Proceed carefully") == "arrow.up")
    }
}

// MARK: - State Reset Tests

@Suite("NavigationStateManager state")
@MainActor
struct NavigationStateManagerStateTests {

    @Test("Initial state has sensible defaults")
    func initialDefaults() {
        let manager = NavigationStateManager()

        #expect(manager.isNavigating == false)
        #expect(manager.isCarPlayActive == false)
        #expect(manager.instruction == "")
        #expect(manager.stepDistance == "")
        #expect(manager.stepDistanceRaw == 0)
        #expect(manager.etaMinutes == 0)
        #expect(manager.distanceRemaining == "")
        #expect(manager.arrivalTime == "")
        #expect(manager.roadName == "")
        #expect(manager.maneuverType == "arrow.up")
        #expect(manager.followOnInstruction == "")
        #expect(manager.followOnManeuverSymbol == "")
        #expect(manager.currentSpeedMph == 0)
        #expect(manager.speedLimitMph == nil)
        #expect(manager.headingDegrees == nil)
        #expect(manager.currentCoordinate == nil)
        #expect(manager.hasArrived == false)
        #expect(manager.activeCommute == nil)
        #expect(manager.activeDirection == nil)
        #expect(manager.rerouteSuggestion == nil)
        #expect(manager.currentRemainingETA == 0)
        #expect(manager.upcomingSteps.isEmpty)
    }

    @Test("stopObserving resets all properties to defaults")
    func stopObservingResetsState() {
        let manager = NavigationStateManager()

        // Simulate having some state set
        manager.isNavigating = true
        manager.isCarPlayActive = true
        manager.instruction = "Turn left"
        manager.stepDistance = "0.3 mi"
        manager.stepDistanceRaw = 482.8
        manager.etaMinutes = 15
        manager.distanceRemaining = "5.2 mi"
        manager.arrivalTime = "3:45 PM"
        manager.roadName = "Main St"
        manager.maneuverType = "arrow.turn.up.left"
        manager.followOnInstruction = "Then turn right"
        manager.followOnManeuverSymbol = "arrow.turn.up.right"
        manager.currentSpeedMph = 45.0
        manager.speedLimitMph = 55.0
        manager.headingDegrees = 180.0
        manager.hasArrived = false
        manager.currentRemainingETA = 900

        manager.stopObserving()

        #expect(manager.isNavigating == false)
        #expect(manager.instruction == "")
        #expect(manager.stepDistance == "")
        #expect(manager.stepDistanceRaw == 0)
        #expect(manager.etaMinutes == 0)
        #expect(manager.distanceRemaining == "")
        #expect(manager.arrivalTime == "")
        #expect(manager.roadName == "")
        #expect(manager.maneuverType == "arrow.up")
        #expect(manager.followOnInstruction == "")
        #expect(manager.followOnManeuverSymbol == "")
        #expect(manager.currentSpeedMph == 0)
        #expect(manager.speedLimitMph == nil)
        #expect(manager.headingDegrees == nil)
        #expect(manager.currentCoordinate == nil)
        #expect(manager.hasArrived == false)
        #expect(manager.activeCommute == nil)
        #expect(manager.activeDirection == nil)
        #expect(manager.rerouteSuggestion == nil)
        #expect(manager.currentRemainingETA == 0)
        #expect(manager.upcomingSteps.isEmpty)
    }

    @Test("stopObserving is idempotent")
    func stopObservingIdempotent() {
        let manager = NavigationStateManager()
        manager.instruction = "Turn left"

        manager.stopObserving()
        manager.stopObserving()

        #expect(manager.instruction == "")
        #expect(manager.isNavigating == false)
    }

    @Test("Default maneuver type is arrow.up")
    func defaultManeuverType() {
        let manager = NavigationStateManager()
        #expect(manager.maneuverType == "arrow.up")
    }
}

// MARK: - Pose Copy Tests

@Suite("NavigationStateManager pose copy")
@MainActor
struct NavigationStateManagerPoseCopyTests {

    @Test("syncFromEngine copies the snapped pose, not the raw coordinate")
    func copiesSnappedPose() throws {
        let engine = NavigationEngine()
        let polyline = (0...10).map { CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.001, longitude: -117.0) }
        let steps = [
            NavStep(instruction: "", distance: 1000, coordinate: polyline[0], maneuverSymbol: "arrow.up"),
            NavStep(instruction: "", distance: 0, coordinate: polyline[10], maneuverSymbol: "flag.fill"),
        ]
        engine.startNavigation(polyline: polyline, steps: steps)

        // ~18m east of the route line, halfway along
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 33.005, longitude: -116.9998),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: -1, courseAccuracy: -1, speed: 13, speedAccuracy: 1,
            timestamp: Date()
        )
        engine.updateLocation(location)

        let manager = NavigationStateManager()
        manager.syncFromEngine(engine)

        let enginePose = try #require(engine.navPose)
        let copied = try #require(manager.currentPose)
        #expect(copied.distanceAlongRoute == enginePose.distanceAlongRoute)
        #expect(copied.segmentIndex == enginePose.segmentIndex)
        #expect(copied.snappedCoordinate.latitude == enginePose.snappedCoordinate.latitude)
        #expect(copied.snappedCoordinate.longitude == enginePose.snappedCoordinate.longitude)
        #expect(copied.fixTimestamp == enginePose.fixTimestamp)
        // CarPlay must read the SNAPPED position, not the raw GPS coordinate
        #expect(copied.snappedCoordinate.longitude != location.coordinate.longitude)
        #expect(manager.headingDegrees == engine.headingDegrees)

        manager.stopObserving()
        #expect(manager.currentPose == nil)
        engine.stopNavigation()
    }
}

// MARK: - Widget ETA Sync Tests

@Suite("NavigationStateManager widget ETA sync")
@MainActor
struct NavigationStateManagerWidgetSyncTests {

    private static let widgetSuite = "group.to.nathancurtis.steddi"

    private func startedEngine(etaMinutes: Int) -> NavigationEngine {
        let engine = NavigationEngine()
        let polyline = (0...10).map { CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.001, longitude: -117.0) }
        let steps = [
            NavStep(instruction: "", distance: 1000, coordinate: polyline[0], maneuverSymbol: "arrow.up"),
            NavStep(instruction: "", distance: 0, coordinate: polyline[10], maneuverSymbol: "flag.fill"),
        ]
        engine.startNavigation(polyline: polyline, steps: steps)
        return engine
    }

    /// The widget read its ETA from a value written once at session start and
    /// never refreshed thereafter, so it froze. Each sync must now push the
    /// engine's current ETA into the shared App Group defaults the widget reads.
    @Test("syncFromEngine writes the current ETA to shared widget defaults")
    func syncWritesWidgetETA() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.widgetSuite))
        let engine = startedEngine(etaMinutes: 0)
        let manager = NavigationStateManager()

        manager.syncFromEngine(engine)
        #expect(defaults.integer(forKey: "widget.etaMinutes") == engine.etaMinutes)
        #expect(defaults.bool(forKey: "widget.isNavigating") == engine.isNavigating)

        manager.stopObserving()
        engine.stopNavigation()
    }

    /// The widget showed an ETA only while actively navigating. Each live sync
    /// now also stamps when the ETA was computed so the widget can present an
    /// idle value as "last known" rather than a frozen live number.
    @Test("syncFromEngine stamps the ETA update time")
    func syncStampsUpdateTime() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.widgetSuite))
        defaults.removeObject(forKey: "widget.etaUpdatedAt")
        let engine = startedEngine(etaMinutes: 0)
        let manager = NavigationStateManager()

        let before = Date().timeIntervalSince1970
        manager.syncFromEngine(engine)
        let stamped = defaults.double(forKey: "widget.etaUpdatedAt")
        #expect(stamped >= before)

        manager.stopObserving()
        engine.stopNavigation()
    }

    /// Idle widget usefulness: pushing a next-commute ETA while not navigating
    /// writes the value the home-screen widget reads pre-drive.
    @Test("updateIdleCommuteETA writes a glanceable ETA when not navigating")
    func idleETAWritesWhenIdle() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.widgetSuite))
        let manager = NavigationStateManager()
        #expect(manager.isNavigating == false)

        manager.updateIdleCommuteETA(commuteName: "Work", destinationName: "Office", etaMinutes: 27)

        #expect(defaults.integer(forKey: "widget.etaMinutes") == 27)
        #expect(defaults.string(forKey: "widget.commuteName") == "Work")
        #expect(defaults.string(forKey: "widget.destinationName") == "Office")
        #expect(defaults.bool(forKey: "widget.isNavigating") == false)
        #expect(defaults.double(forKey: "widget.etaUpdatedAt") > 0)
    }

    /// The idle push must never clobber a live ETA mid-drive.
    @Test("updateIdleCommuteETA is a no-op while navigating")
    func idleETANoOpWhileNavigating() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.widgetSuite))
        defaults.set(99, forKey: "widget.etaMinutes")
        let manager = NavigationStateManager()
        manager.isNavigating = true

        manager.updateIdleCommuteETA(commuteName: "X", destinationName: "Y", etaMinutes: 5)

        #expect(defaults.integer(forKey: "widget.etaMinutes") == 99)

        manager.isNavigating = false
    }

    /// A non-positive idle ETA carries no information and must be ignored so the
    /// widget keeps a previously known good value rather than going blank.
    @Test("updateIdleCommuteETA ignores non-positive ETA")
    func idleETAIgnoresNonPositive() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.widgetSuite))
        defaults.set(42, forKey: "widget.etaMinutes")
        let manager = NavigationStateManager()

        manager.updateIdleCommuteETA(commuteName: "X", destinationName: "Y", etaMinutes: 0)

        #expect(defaults.integer(forKey: "widget.etaMinutes") == 42)
    }

    /// Bug: after a drive, the last live sync wrote the near-arrival remaining
    /// ETA (~1-2 min) plus a fresh timestamp. clearWidgetSession kept both, so
    /// the idle "Next Commute" widget showed the finished drive's terminal
    /// minutes as the upcoming commute's ETA — and the fresh stamp kept isStale
    /// false for 30 min, presenting it as live. On end the live ETA must be
    /// cleared (0 -> widget renders "No ETA yet") and its stamp dropped, so the
    /// idle path can repopulate a real pre-drive ETA.
    @Test("Ending navigation clears the terminal live ETA so it isn't shown as the next commute")
    func endClearsTerminalLiveETA() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.widgetSuite))
        let engine = startedEngine(etaMinutes: 0)
        let manager = NavigationStateManager()

        // Begin a session, then sync a near-arrival "remaining" ETA as the last
        // live write before the drive ends.
        manager.startObserving(engine: engine, destinationName: "Office")
        defaults.set(2, forKey: "widget.etaMinutes")
        defaults.set(Date().timeIntervalSince1970, forKey: "widget.etaUpdatedAt")

        // Drive ends.
        manager.stopObserving()

        // The terminal remaining-ETA must NOT survive as the idle value.
        #expect(defaults.integer(forKey: "widget.etaMinutes") == 0)
        // And no recent timestamp should be left to defeat the freshness guard.
        #expect(defaults.double(forKey: "widget.etaUpdatedAt") == 0)
        // Session flagged idle.
        #expect(defaults.bool(forKey: "widget.isNavigating") == false)

        engine.stopNavigation()
    }

    /// Crash-orphan guard: an OOM/watchdog kill mid-drive leaves the App Group's
    /// kIsNavigating stuck true with a near-arrival ETA, so the widget shows a
    /// phantom live nav forever. At launch (not navigating) the reconcile must
    /// clear the flag and zero the stale live ETA.
    @Test("reconcileWidgetSessionAtLaunch clears a crash-orphaned navigating flag when idle")
    func reconcileClearsStaleNavigatingFlag() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.widgetSuite))
        // Simulate the App Group left behind by a crash mid-drive.
        defaults.set(true, forKey: "widget.isNavigating")
        defaults.set(2, forKey: "widget.etaMinutes")
        defaults.set(Date().timeIntervalSince1970, forKey: "widget.etaUpdatedAt")

        let manager = NavigationStateManager()
        #expect(manager.isNavigating == false)

        manager.reconcileWidgetSessionAtLaunch()

        #expect(defaults.bool(forKey: "widget.isNavigating") == false)
        #expect(defaults.integer(forKey: "widget.etaMinutes") == 0)
        #expect(defaults.double(forKey: "widget.etaUpdatedAt") == 0)
    }

    /// The reconcile must not wipe a legitimate idle ETA snapshot — it only acts
    /// when the orphaned navigating flag is set.
    @Test("reconcileWidgetSessionAtLaunch leaves a clean idle snapshot untouched")
    func reconcileNoOpWhenAlreadyIdle() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.widgetSuite))
        defaults.set(false, forKey: "widget.isNavigating")
        defaults.set(31, forKey: "widget.etaMinutes")
        let stamp = Date().timeIntervalSince1970
        defaults.set(stamp, forKey: "widget.etaUpdatedAt")

        let manager = NavigationStateManager()
        manager.reconcileWidgetSessionAtLaunch()

        // Idle pre-drive ETA preserved.
        #expect(defaults.integer(forKey: "widget.etaMinutes") == 31)
        #expect(defaults.double(forKey: "widget.etaUpdatedAt") == stamp)
        #expect(defaults.bool(forKey: "widget.isNavigating") == false)
    }

    /// Must not clobber a genuinely live session (e.g. a CarPlay-first relaunch
    /// into an active drive where isNavigating is already true).
    @Test("reconcileWidgetSessionAtLaunch is a no-op while actually navigating")
    func reconcileNoOpWhileNavigating() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.widgetSuite))
        defaults.set(true, forKey: "widget.isNavigating")
        defaults.set(7, forKey: "widget.etaMinutes")

        let manager = NavigationStateManager()
        manager.isNavigating = true

        manager.reconcileWidgetSessionAtLaunch()

        #expect(defaults.bool(forKey: "widget.isNavigating") == true)
        #expect(defaults.integer(forKey: "widget.etaMinutes") == 7)

        manager.isNavigating = false
    }
}

// MARK: - Active Trip Teardown Tests

@Suite("NavigationStateManager active trip teardown")
@MainActor
struct NavigationStateManagerTripTeardownTests {

    private func startedEngine() -> NavigationEngine {
        let engine = NavigationEngine()
        let polyline = (0...10).map { CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.001, longitude: -117.0) }
        let steps = [
            NavStep(instruction: "", distance: 1000, coordinate: polyline[0], maneuverSymbol: "arrow.up"),
            NavStep(instruction: "", distance: 0, coordinate: polyline[10], maneuverSymbol: "flag.fill"),
        ]
        engine.startNavigation(polyline: polyline, steps: steps)
        return engine
    }

    /// Deleting the actively-navigated trip routes through endActiveTripSession.
    /// It must stop the engine, end the session (isNavigating -> false, the edge
    /// HomeView observes to tear down its own overlay/@State), and clear
    /// activeTrip so nothing is left pointing at the deleted model.
    @Test("endActiveTripSession stops the engine and clears the session")
    func endActiveTripSessionTearsDown() {
        let manager = NavigationStateManager()
        let engine = startedEngine()
        let trip = Trip(name: "Errands")

        manager.startObserving(engine: engine, trip: trip)
        #expect(manager.isNavigating == true)
        #expect(manager.activeTrip != nil)
        #expect(engine.isNavigating == true)

        manager.endActiveTripSession()

        // Engine stopped so no further ticks fire on the deleted trip.
        #expect(engine.isNavigating == false)
        // isNavigating flipped false — the edge HomeView's onChange observes to
        // drive its own teardown (overlay dismissal, GPS mode, Live Activity).
        #expect(manager.isNavigating == false)
        // Nothing left pointing at the model that's about to be deleted.
        #expect(manager.activeTrip == nil)
        #expect(manager.activeEngine == nil)
    }

    /// endActiveTripSession is the teardown HomeView keys off, so it must be
    /// safe to call when no session is active (e.g. a stale call) without
    /// crashing or leaving partial state.
    @Test("endActiveTripSession is safe with no active session")
    func endActiveTripSessionIdempotent() {
        let manager = NavigationStateManager()

        manager.endActiveTripSession()
        manager.endActiveTripSession()

        #expect(manager.isNavigating == false)
        #expect(manager.activeTrip == nil)
        #expect(manager.activeEngine == nil)
    }
}

// MARK: - Session Generation Tests

@Suite("NavigationStateManager session generation")
@MainActor
struct NavigationStateManagerSessionGenerationTests {

    private func startedEngine() -> NavigationEngine {
        let engine = NavigationEngine()
        let polyline = (0...10).map { CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.001, longitude: -117.0) }
        let steps = [
            NavStep(instruction: "", distance: 1000, coordinate: polyline[0], maneuverSymbol: "arrow.up"),
            NavStep(instruction: "", distance: 0, coordinate: polyline[10], maneuverSymbol: "flag.fill"),
        ]
        engine.startNavigation(polyline: polyline, steps: steps)
        return engine
    }

    /// CarPlay re-presents nav for each continuous trip leg by watching this
    /// counter, since isNavigating never observably dips to false between legs.
    @Test("startObserving bumps sessionGeneration each session")
    func generationBumpsPerSession() {
        let manager = NavigationStateManager()
        let engine = startedEngine()

        let g0 = manager.sessionGeneration
        manager.startObserving(engine: engine)
        let g1 = manager.sessionGeneration
        #expect(g1 == g0 + 1)

        // Simulate the inter-leg restart: startObserving again without an
        // intervening observable isNavigating=false to the CarPlay sampler.
        manager.startObserving(engine: engine)
        let g2 = manager.sessionGeneration
        #expect(g2 == g1 + 1)

        manager.stopObserving()
        engine.stopNavigation()
    }
}
