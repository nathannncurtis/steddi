import Foundation

/// UserDefaults / `@AppStorage` keys for the custom-routing feature flag.
enum CustomRoutingDefaultsKey {
    /// Global opt-in for the custom road-graph router. DEFAULT FALSE — MapKit
    /// stays the user-facing path until the flag is flipped (§7.3, Phase-5).
    static let enabled = "steddi.useCustomRouter"
}

/// Reads the global custom-routing flag. A tiny indirection so the selector and
/// the Settings toggle agree on the key and the false-by-default semantics, and
/// so the read is injectable in tests (no `.standard` coupling).
enum CustomRoutingFlag {
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: CustomRoutingDefaultsKey.enabled)   // absent => false
    }
}

/// Selects the route generation engine per request and guarantees a route never
/// regresses to "none".
///
/// When the custom-routing flag is OFF, every request goes straight to MapKit
/// (`DirectionsService`) — user-facing behavior is unchanged. When ON, the
/// custom router is tried first and, **if it returns nil** (corridor graph not
/// loaded, no path, degraded synthesis), the request **automatically falls back
/// to MapKit** for that one request. MapKit is therefore always the safety net,
/// exactly the seam the spec mandates (§7.2).
///
/// This is the single object call sites talk to; they never branch on the flag
/// themselves, keeping the integration edits surgical.
@MainActor
final class RouteProviderSelector {

    private let custom: RouteProvider
    private let fallback: RouteProvider
    private let isCustomEnabled: () -> Bool

    /// - Parameters:
    ///   - custom: the primary provider when enabled (the road-graph router).
    ///   - fallback: the always-available MapKit provider.
    ///   - isCustomEnabled: reads the live flag (defaults to the global one).
    init(
        custom: RouteProvider,
        fallback: RouteProvider,
        isCustomEnabled: @escaping () -> Bool = { CustomRoutingFlag.isEnabled() }
    ) {
        self.custom = custom
        self.fallback = fallback
        self.isCustomEnabled = isCustomEnabled
    }

    /// Convenience: build the production selector wiring `CustomRouter` over a
    /// shared `RoadGraphSource`, with `DirectionsService` as the fallback.
    convenience init(
        graphSource: RoadGraphSource,
        directionsService: DirectionsService = DirectionsService(),
        isCustomEnabled: @escaping () -> Bool = { CustomRoutingFlag.isEnabled() }
    ) {
        self.init(
            custom: CustomRouter(graphSource: graphSource),
            fallback: directionsService,
            isCustomEnabled: isCustomEnabled
        )
    }

    /// Generate a route, choosing the engine by the flag and falling back to
    /// MapKit automatically when the custom router yields nil. Returns the route
    /// (with its `source` provenance set) or nil only when MapKit itself fails.
    func generateRoute(_ request: RouteRequest) async -> GeneratedRoute? {
        if isCustomEnabled() {
            if let custom = await custom.generateRoute(request) {
                return custom
            }
            // Automatic fallback: the custom router couldn't serve this request.
        }
        return await fallback.generateRoute(request)
    }
}

/// Builds the app's `RouteProviderSelector`. Keeping construction in one place
/// means call sites get the selector without reaching for the flag or the graph
/// source directly.
@MainActor
enum RouteProviderFactory {
    /// The shared corridor graph source, lazily created once so its cache and the
    /// active corridor are reused across route requests in a session.
    static let sharedGraphSource = RoadGraphSource()

    /// The production selector: custom router (over the shared graph source) with
    /// MapKit fallback, gated by the global flag.
    static func makeSelector(
        directionsService: DirectionsService = DirectionsService()
    ) -> RouteProviderSelector {
        RouteProviderSelector(
            graphSource: sharedGraphSource,
            directionsService: directionsService
        )
    }
}
