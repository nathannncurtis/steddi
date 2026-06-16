import Testing
import Foundation
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
#endif
@testable import Steddi

// MARK: - Helpers

private let testLocation = CLLocation(latitude: 33.0, longitude: -117.0)

/// A non-entitlement transient error, the kind a momentary network blip or a
/// WeatherKit backend hiccup surfaces.
private func transientError() -> Error {
    URLError(.timedOut)
}

/// A WeatherKit auth/entitlement URLError (auth required), which IS permanent.
private func authURLError() -> Error {
    NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)
}

/// The WeatherDaemon JWT authenticator domain error — a genuine entitlement
/// failure surfaced by the WeatherKit auth pipeline.
private func jwtAuthError() -> Error {
    NSError(domain: "WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors", code: 1)
}

// MARK: - isEntitlementFailure classification

@Suite("WeatherKitService.isEntitlementFailure")
struct WeatherKitEntitlementClassificationTests {

    @Test("Transient URLError is NOT an entitlement failure")
    func transientURLErrorIsTransient() {
        #expect(WeatherKitService.isEntitlementFailure(transientError()) == false)
    }

    #if canImport(WeatherKit)
    @Test("WeatherError.unknown is NOT an entitlement failure (transient catch-all)")
    func weatherErrorUnknownIsTransient() {
        #expect(WeatherKitService.isEntitlementFailure(WeatherError.unknown) == false)
    }

    @Test("WeatherError.permissionDenied IS an entitlement failure")
    func weatherErrorPermissionDeniedIsEntitlement() {
        #expect(WeatherKitService.isEntitlementFailure(WeatherError.permissionDenied) == true)
    }
    #endif

    @Test("Auth-required URLError IS an entitlement failure")
    func authURLErrorIsEntitlement() {
        #expect(WeatherKitService.isEntitlementFailure(authURLError()) == true)
    }

    @Test("JWT authenticator domain error IS an entitlement failure")
    func jwtErrorIsEntitlement() {
        #expect(WeatherKitService.isEntitlementFailure(jwtAuthError()) == true)
    }
}

// MARK: - refresh() availability behavior

@Suite("WeatherKitService refresh availability")
@MainActor
struct WeatherKitRefreshAvailabilityTests {

    /// Build a service whose provider always throws `error`, with theming
    /// applications routed to a no-op so we observe only availability state.
    private func makeService(throwing error: Error, now: @escaping () -> Date) -> WeatherKitService {
        WeatherKitService(
            provider: { _ in throw error },
            now: now,
            apply: { _, _ in }
        )
    }

    @Test("A transient error does NOT arm the 6-hour disable")
    func transientErrorKeepsServiceAvailable() async {
        let service = makeService(throwing: transientError(), now: { Date() })
        #expect(service.isAvailable)

        await service.refresh(at: testLocation)

        // The blip degraded this one cycle to heuristics but must leave the
        // service available so the very next refresh tries WeatherKit again.
        #expect(service.isAvailable)
    }

    #if canImport(WeatherKit)
    @Test("WeatherError.unknown does NOT arm the 6-hour disable")
    func weatherErrorUnknownKeepsServiceAvailable() async {
        let service = makeService(throwing: WeatherError.unknown, now: { Date() })
        await service.refresh(at: testLocation)
        #expect(service.isAvailable)
    }

    @Test("An entitlement failure arms the disable")
    func entitlementFailureDisablesService() async {
        let service = makeService(throwing: WeatherError.permissionDenied, now: { Date() })
        #expect(service.isAvailable)

        await service.refresh(at: testLocation)

        // A genuine entitlement failure is the only thing that should disable
        // WeatherKit and arm the long backoff.
        #expect(service.isAvailable == false)
    }
    #endif

    @Test("An auth-required failure arms the disable")
    func authFailureDisablesService() async {
        let service = makeService(throwing: authURLError(), now: { Date() })
        await service.refresh(at: testLocation)
        #expect(service.isAvailable == false)
    }
}
