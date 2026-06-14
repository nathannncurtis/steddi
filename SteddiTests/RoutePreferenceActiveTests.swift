import Testing
import Foundation
import MapKit
@testable import Steddi

/// Covers the preference-active detection that drives the nav-overlay and
/// route-preview "Avoiding tolls / highways" indicators: resolution layering
/// against an injected defaults store, the `isActive` gate, and the ordered,
/// human-facing `activeLabels`.
@Suite("Route preference active detection", .serialized)
struct RoutePreferenceActiveTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "RoutePreferenceActiveTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - isActive

    @Test("isActive is false when neither preference avoids anything")
    func inactiveWhenNeitherSet() {
        let prefs = RoutePreferences(avoidsTolls: false, avoidsHighways: false)
        #expect(prefs.isActive == false)
    }

    @Test("isActive is true when tolls are avoided")
    func activeWhenAvoidingTolls() {
        let prefs = RoutePreferences(avoidsTolls: true, avoidsHighways: false)
        #expect(prefs.isActive)
    }

    @Test("isActive is true when highways are avoided")
    func activeWhenAvoidingHighways() {
        let prefs = RoutePreferences(avoidsTolls: false, avoidsHighways: true)
        #expect(prefs.isActive)
    }

    // MARK: - activeLabels

    @Test("No active labels when nothing is avoided")
    func noLabelsWhenInactive() {
        let prefs = RoutePreferences(avoidsTolls: false, avoidsHighways: false)
        #expect(prefs.activeLabels.isEmpty)
    }

    @Test("Toll-only avoidance yields a single tolls label")
    func tollsOnlyLabel() {
        let prefs = RoutePreferences(avoidsTolls: true, avoidsHighways: false)
        #expect(prefs.activeLabels == ["Avoiding tolls"])
    }

    @Test("Highway-only avoidance yields a single highways label")
    func highwaysOnlyLabel() {
        let prefs = RoutePreferences(avoidsTolls: false, avoidsHighways: true)
        #expect(prefs.activeLabels == ["Avoiding highways"])
    }

    @Test("Both avoidances yield tolls before highways, stably")
    func bothLabelsOrdered() {
        let prefs = RoutePreferences(avoidsTolls: true, avoidsHighways: true)
        #expect(prefs.activeLabels == ["Avoiding tolls", "Avoiding highways"])
    }

    // MARK: - Resolution layering (injected defaults)

    @Test("Resolves the global defaults when no commute override is present")
    func resolvesGlobalDefaults() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: RoutePreferenceDefaultsKey.avoidsTolls)
        defaults.set(false, forKey: RoutePreferenceDefaultsKey.avoidsHighways)

        let prefs = RoutePreferences.resolve(commute: nil, in: defaults)
        #expect(prefs.avoidsTolls)
        #expect(prefs.avoidsHighways == false)
        #expect(prefs.activeLabels == ["Avoiding tolls"])
    }

    @Test("Unset global defaults resolve to no avoidance")
    func resolvesUnsetDefaultsToInactive() {
        let defaults = makeDefaults()
        let prefs = RoutePreferences.resolve(commute: nil, in: defaults)
        #expect(prefs.isActive == false)
        #expect(prefs.activeLabels.isEmpty)
    }

    @Test("A commute override beats the global default for tolls")
    func commuteOverrideBeatsGlobalTolls() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: RoutePreferenceDefaultsKey.avoidsTolls)
        defaults.set(false, forKey: RoutePreferenceDefaultsKey.avoidsHighways)

        let commute = Commute(name: "Test")
        commute.avoidsTolls = true

        let prefs = RoutePreferences.resolve(commute: commute, in: defaults)
        #expect(prefs.avoidsTolls)
        #expect(prefs.avoidsHighways == false)
    }

    @Test("A nil commute field falls through to the global default")
    func nilCommuteFieldFallsThroughToGlobal() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: RoutePreferenceDefaultsKey.avoidsTolls)
        defaults.set(true, forKey: RoutePreferenceDefaultsKey.avoidsHighways)

        let commute = Commute(name: "Test")
        commute.avoidsTolls = false   // explicit
        // avoidsHighways left nil → inherits the global default

        let prefs = RoutePreferences.resolve(commute: commute, in: defaults)
        #expect(prefs.avoidsTolls == false)
        #expect(prefs.avoidsHighways)
        #expect(prefs.activeLabels == ["Avoiding highways"])
    }

    @Test("An explicit commute opt-out beats a global default that avoids")
    func commuteOptOutBeatsGlobalAvoidance() {
        // Global says avoid both; this commute explicitly opts back in to both.
        // `false ?? true` must resolve to the explicit false, not the global.
        let defaults = makeDefaults()
        defaults.set(true, forKey: RoutePreferenceDefaultsKey.avoidsTolls)
        defaults.set(true, forKey: RoutePreferenceDefaultsKey.avoidsHighways)

        let commute = Commute(name: "Test")
        commute.avoidsTolls = false      // explicit opt-out
        commute.avoidsHighways = false   // explicit opt-out

        let prefs = RoutePreferences.resolve(commute: commute, in: defaults)
        #expect(prefs.avoidsTolls == false)
        #expect(prefs.avoidsHighways == false)
        #expect(prefs.isActive == false)
        #expect(prefs.activeLabels.isEmpty)
    }

    @Test("A commute override beats the global default for highways")
    func commuteOverrideBeatsGlobalHighways() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: RoutePreferenceDefaultsKey.avoidsTolls)
        defaults.set(false, forKey: RoutePreferenceDefaultsKey.avoidsHighways)

        let commute = Commute(name: "Test")
        commute.avoidsHighways = true

        let prefs = RoutePreferences.resolve(commute: commute, in: defaults)
        #expect(prefs.avoidsTolls == false)
        #expect(prefs.avoidsHighways)
        #expect(prefs.activeLabels == ["Avoiding highways"])
    }

    @Test("Both global defaults set resolves both, tolls before highways")
    func resolvesBothGlobalDefaultsOrdered() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: RoutePreferenceDefaultsKey.avoidsTolls)
        defaults.set(true, forKey: RoutePreferenceDefaultsKey.avoidsHighways)

        let prefs = RoutePreferences.resolve(commute: nil, in: defaults)
        #expect(prefs.isActive)
        #expect(prefs.activeLabels == ["Avoiding tolls", "Avoiding highways"])
    }

    @Test("A nil commute argument resolves purely from the global defaults")
    func nilCommuteArgumentUsesGlobals() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: RoutePreferenceDefaultsKey.avoidsTolls)
        defaults.set(false, forKey: RoutePreferenceDefaultsKey.avoidsHighways)

        // The whole commute is nil (not just a field) — both come from globals.
        let prefs = RoutePreferences.resolve(commute: nil, in: defaults)
        #expect(prefs.avoidsTolls)
        #expect(prefs.avoidsHighways == false)
    }

    // MARK: - apply(to:) mapping

    @Test("apply maps avoidance flags onto an MKDirections request")
    func applyMapsAvoidanceToRequest() {
        let request = MKDirections.Request()

        RoutePreferences(avoidsTolls: true, avoidsHighways: false).apply(to: request)
        #expect(request.tollPreference == .avoid)
        #expect(request.highwayPreference == .any)

        RoutePreferences(avoidsTolls: false, avoidsHighways: true).apply(to: request)
        #expect(request.tollPreference == .any)
        #expect(request.highwayPreference == .avoid)
    }
}
