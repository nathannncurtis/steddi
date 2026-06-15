import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - Geocoding Proximity Re-rank Tests

@Suite("GeocodingService.rank proximity re-rank")
struct GeocodingServiceRankTests {

    /// The user sits at this coordinate; proximity should bias toward it.
    private static let user = CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0)

    /// Build a `(result, apiRank)` window. `apiRank` is the MKLocalSearch
    /// relevance order (0 = most relevant). The coordinate offset (degrees east)
    /// controls how far each result is from the user.
    private func entry(rank: Int, eastDegrees: Double) -> (result: GeocodingResult, apiRank: Int) {
        let coord = CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0 + eastDegrees)
        let result = GeocodingResult(name: "place-\(rank)", address: "addr", coordinate: coord)
        return (result: result, apiRank: rank)
    }

    @Test("A nearer result ranked just outside the relevance cut survives the truncation")
    func nearerResultOutsideCutSurvives() {
        let limit = 10
        // Ten relevance-top-N results, all far away (~0.5 degrees ≈ 46km east).
        var window: [(result: GeocodingResult, apiRank: Int)] = (0..<limit).map {
            entry(rank: $0, eastDegrees: 0.5)
        }
        // An 11th result (rank 10) that Apple ranked just outside the top-10 but
        // sits almost on top of the user — the exact case the old prefix-before-sort
        // dropped before proximity could see it.
        let nearby = entry(rank: limit, eastDegrees: 0.0005) // ~46m away
        window.append(nearby)

        let ranked = GeocodingService.rank(window, proximity: Self.user, limit: limit)

        #expect(ranked.count == limit)
        // The nearby low-relevance result must be present in the returned set...
        #expect(ranked.contains { $0.name == nearby.result.name })
        // ...and proximity weighting (60%) should float it to the front.
        #expect(ranked.first?.name == nearby.result.name)
    }

    @Test("With no proximity, relevance order is preserved and truncated to limit")
    func noProximityKeepsRelevanceOrder() {
        let limit = 3
        let window = (0..<6).map { entry(rank: $0, eastDegrees: Double($0) * 0.1) }
        let ranked = GeocodingService.rank(window, proximity: nil, limit: limit)
        #expect(ranked.count == limit)
        #expect(ranked.map(\.name) == ["place-0", "place-1", "place-2"])
    }
}
