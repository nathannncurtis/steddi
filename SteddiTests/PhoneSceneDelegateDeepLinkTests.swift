import Testing
import Foundation
@testable import Steddi

// Covers `PhoneSceneDelegate`'s deep-link resolution. The `steddi://` scheme
// ships in the release Info.plist, so these URLs are fully attacker-controlled
// and can arrive during cold-launch scene connection. The bar: resolution must
// be total — never trap on duplicate query keys, missing/empty/extra params, or
// unknown hosts — while still routing valid links correctly.
@Suite("PhoneSceneDelegate deep-link resolution")
struct PhoneSceneDelegateDeepLinkTests {

    private func url(_ s: String) -> URL {
        // The strings under test are all well-formed enough for URL to parse;
        // a nil here is itself a test failure.
        guard let u = URL(string: s) else {
            Issue.record("Could not build URL from \(s)")
            return URL(string: "steddi://invalid")!
        }
        return u
    }

    // MARK: - Duplicate query keys (the crash this fix addresses)

    @Test("Duplicate query keys do not trap and resolve to a sane route")
    func duplicateKeysDoNotCrash() {
        // Previously `Dictionary(uniqueKeysWithValues:)` fatal-trapped here.
        let route = PhoneSceneDelegate.resolveRoute(
            from: url("steddi://search?q=a&q=b")
        )
        // First-occurrence-wins: the repeated key must not crash, and resolves
        // to the first value.
        #expect(route == .search(query: "a"))
    }

    @Test("Duplicate lat/lng keys resolve to the first coordinate, no trap")
    func duplicateCoordinateKeys() {
        let route = PhoneSceneDelegate.resolveRoute(
            from: url("steddi://navigate?lat=1&lat=2&lng=3&lng=4")
        )
        #expect(route == .navigate(name: "Destination", latitude: 1, longitude: 3))
    }

    @Test("Repeated key on an unknown host still does not trap")
    func duplicateKeysUnknownHost() {
        // The dictionary was built before the host switch, so even an
        // unrecognized host with a repeated query name used to crash.
        let route = PhoneSceneDelegate.resolveRoute(
            from: url("steddi://anything?x=1&x=2")
        )
        #expect(route == nil)
    }

    @Test("queryParams keeps the first occurrence of a duplicated key")
    func queryParamsFirstWins() {
        let params = PhoneSceneDelegate.queryParams(
            from: url("steddi://x?a=1&a=2&b=3")
        )
        #expect(params["a"] == "1")
        #expect(params["b"] == "3")
    }

    // MARK: - Malformed / empty / unknown input is ignored gracefully

    @Test("Unknown host resolves to nil")
    func unknownHost() {
        #expect(PhoneSceneDelegate.resolveRoute(from: url("steddi://bogus")) == nil)
    }

    @Test("Navigate with missing coordinates is ignored")
    func navigateMissingCoords() {
        #expect(PhoneSceneDelegate.resolveRoute(from: url("steddi://navigate")) == nil)
        #expect(PhoneSceneDelegate.resolveRoute(from: url("steddi://navigate?lat=1")) == nil)
    }

    @Test("Navigate with non-numeric coordinates is ignored")
    func navigateNonNumericCoords() {
        #expect(
            PhoneSceneDelegate.resolveRoute(from: url("steddi://navigate?lat=abc&lng=def")) == nil
        )
    }

    @Test("Search with empty or missing query is ignored")
    func searchEmptyQuery() {
        #expect(PhoneSceneDelegate.resolveRoute(from: url("steddi://search")) == nil)
        #expect(PhoneSceneDelegate.resolveRoute(from: url("steddi://search?q=")) == nil)
    }

    @Test("Navigate with a bogus commuteId is ignored")
    func navigateBogusCommuteId() {
        #expect(
            PhoneSceneDelegate.resolveRoute(from: url("steddi://navigate?commuteId=not-a-uuid")) == nil
        )
    }

    @Test("Extra/unrecognized params do not break a valid route")
    func extraParamsTolerated() {
        let route = PhoneSceneDelegate.resolveRoute(
            from: url("steddi://search?q=coffee&utm_source=qr&ref=abc")
        )
        #expect(route == .search(query: "coffee"))
    }

    @Test("queryParams on a URL with no query is empty, not a trap")
    func emptyQueryParams() {
        #expect(PhoneSceneDelegate.queryParams(from: url("steddi://places")).isEmpty)
    }

    // MARK: - Valid links still route correctly

    @Test("Valid navigate routes with coordinates and name")
    func validNavigate() {
        let route = PhoneSceneDelegate.resolveRoute(
            from: url("steddi://navigate?lat=37.33&lng=-122.03&name=Apple%20Park")
        )
        #expect(route == .navigate(name: "Apple Park", latitude: 37.33, longitude: -122.03))
    }

    @Test("Valid navigate without a name defaults to Destination")
    func navigateDefaultName() {
        let route = PhoneSceneDelegate.resolveRoute(
            from: url("steddi://navigate?lat=1.5&lng=2.5")
        )
        #expect(route == .navigate(name: "Destination", latitude: 1.5, longitude: 2.5))
    }

    @Test("Valid commute-start deep link round-trips id and direction")
    func validCommuteStart() {
        let id = UUID()
        let route = PhoneSceneDelegate.resolveRoute(
            from: url("steddi://navigate?commuteId=\(id.uuidString)&direction=originToDestination")
        )
        #expect(route == .startSpecificCommute(commuteId: id, direction: .originToDestination))
    }

    @Test("Commute-start deep link tolerates a missing/invalid direction")
    func commuteStartNilDirection() {
        let id = UUID()
        let route = PhoneSceneDelegate.resolveRoute(
            from: url("steddi://navigate?commuteId=\(id.uuidString)")
        )
        #expect(route == .startSpecificCommute(commuteId: id, direction: nil))
    }

    @Test("start-commute resolves to first-active")
    func validStartCommute() {
        #expect(
            PhoneSceneDelegate.resolveRoute(from: url("steddi://start-commute")) == .startFirstActiveCommute
        )
    }

    @Test("places resolves to show-places")
    func validPlaces() {
        #expect(PhoneSceneDelegate.resolveRoute(from: url("steddi://places")) == .showPlaces)
    }

    @Test("Valid search routes with the query")
    func validSearch() {
        #expect(
            PhoneSceneDelegate.resolveRoute(from: url("steddi://search?q=gym")) == .search(query: "gym")
        )
    }

#if DEBUG
    @Test("DEBUG-only arrive and reset-onboarding routes resolve")
    func debugRoutes() {
        #expect(PhoneSceneDelegate.resolveRoute(from: url("steddi://arrive")) == .testArrival)
        #expect(
            PhoneSceneDelegate.resolveRoute(from: url("steddi://reset-onboarding")) == .resetOnboarding
        )
    }
#endif
}
