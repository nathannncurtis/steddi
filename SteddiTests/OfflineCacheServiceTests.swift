import Testing
import Foundation
@testable import Steddi

@Suite("OfflineCacheService", .serialized)
struct OfflineCacheServiceTests {

    private func makeRoute() -> Route {
        Route(
            rank: 0,
            encodedPolyline: "test_polyline_data",
            distanceMeters: 5000,
            typicalDurationSeconds: 600,
            source: .planned
        )
    }

    // MARK: - Cache

    @Test("Cache and load active route")
    func cacheAndLoad() throws {
        let service = OfflineCacheService()
        let route = makeRoute()

        try service.cacheActiveRoute(route)
        let loaded = try service.loadCachedRoute(route)

        #expect(loaded != nil)
        #expect(loaded?.encodedPolyline == "test_polyline_data")
        #expect(loaded?.distanceMeters == 5000)
        #expect(loaded?.typicalDurationSeconds == 600)

        service.clearCache()
    }

    @Test("isAvailableOffline after caching")
    func availableAfterCache() throws {
        let service = OfflineCacheService()
        let route = makeRoute()

        #expect(!service.isAvailableOffline(route))

        try service.cacheActiveRoute(route)
        #expect(service.isAvailableOffline(route))

        service.clearCache()
        #expect(!service.isAvailableOffline(route))
    }

    // MARK: - Downloads

    @Test("Download and load route")
    func downloadAndLoad() throws {
        let service = OfflineCacheService()
        let route = makeRoute()

        try service.downloadRoute(route)
        #expect(service.downloadedRouteIDs.contains(route.id))
        #expect(service.isAvailableOffline(route))

        let loaded = try service.loadCachedRoute(route)
        #expect(loaded != nil)
        #expect(loaded?.encodedPolyline == "test_polyline_data")

        service.deleteDownloadedRoute(route)
        #expect(!service.downloadedRouteIDs.contains(route.id))
    }

    @Test("Download preferred over cache")
    func downloadPreferredOverCache() throws {
        let service = OfflineCacheService()
        let route = makeRoute()

        try service.cacheActiveRoute(route)
        try service.downloadRoute(route)

        service.clearCache()
        #expect(service.isAvailableOffline(route))

        let loaded = try service.loadCachedRoute(route)
        #expect(loaded != nil)

        service.deleteDownloadedRoute(route)
    }

    @Test("Load nonexistent route returns nil")
    func loadNonexistent() throws {
        let service = OfflineCacheService()
        let route = makeRoute()
        let loaded = try service.loadCachedRoute(route)
        #expect(loaded == nil)
    }
}
