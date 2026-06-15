import Foundation
import CoreLocation
import MapKit

/// Wraps Apple's MKLocalSearch for place search (forward geocoding).
final class GeocodingService {

    init() {}

    /// Search for places matching a query string.
    /// Biases results toward the given proximity coordinate.
    func search(
        query: String,
        proximity: CLLocationCoordinate2D? = nil,
        limit: Int = 10
    ) async throws -> [GeocodingResult] {
        guard !query.isEmpty else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        if let prox = proximity {
            request.region = MKCoordinateRegion(
                center: prox,
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            )
        }

        let localSearch = MKLocalSearch(request: request)
        let response = try await localSearch.start()

        // Parse a wider window than `limit` so the proximity re-rank can pull a
        // nearby low-relevance result into the returned set. MKLocalSearch orders
        // by relevance, so truncating to `limit` BEFORE scoring would discard a
        // closer match Apple ranked just outside the cut. Cap the window so the
        // sort cost stays bounded for pathologically large responses.
        let window = limit * 3
        let parsed = response.mapItems.prefix(window).enumerated().compactMap { (index, mapItem) -> (result: GeocodingResult, apiRank: Int)? in
            let name = mapItem.name ?? "Unknown"
            let coordinate = mapItem.location.coordinate
            let address = mapItem.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true) ?? name

            let geocodingResult = GeocodingResult(
                name: name,
                address: address,
                coordinate: coordinate
            )
            return (result: geocodingResult, apiRank: index)
        }

        return Self.rank(parsed, proximity: proximity, limit: limit)
    }

    /// Combined proximity + relevance ranking, applied over the FULL parsed
    /// window and truncated to `limit` only AFTER sorting — so a nearer result
    /// ranked just outside the relevance cut can still survive. Pure and static
    /// so the ordering is unit-testable without MKLocalSearch.
    static func rank(
        _ parsed: [(result: GeocodingResult, apiRank: Int)],
        proximity: CLLocationCoordinate2D?,
        limit: Int
    ) -> [GeocodingResult] {
        // No proximity to bias toward: keep relevance order, truncate to `limit`.
        guard let prox = proximity else {
            return parsed.prefix(limit).map(\.result)
        }

        let userLocation = CLLocation(latitude: prox.latitude, longitude: prox.longitude)
        let denominator = max(Double(parsed.count), 1.0)

        return parsed.sorted { a, b in
            let distA = userLocation.distance(from: CLLocation(latitude: a.result.coordinate.latitude, longitude: a.result.coordinate.longitude))
            let distB = userLocation.distance(from: CLLocation(latitude: b.result.coordinate.latitude, longitude: b.result.coordinate.longitude))

            // Combined score: API relevance (lower rank = more relevant) + distance penalty
            // Normalize distance to ~0-1 range (50km = 1.0)
            let distScoreA = min(distA / 50_000, 1.0)
            let distScoreB = min(distB / 50_000, 1.0)

            // API rank normalized to 0-1
            let relevanceA = Double(a.apiRank) / denominator
            let relevanceB = Double(b.apiRank) / denominator

            // Weight: 60% proximity, 40% relevance
            let scoreA = distScoreA * 0.6 + relevanceA * 0.4
            let scoreB = distScoreB * 0.6 + relevanceB * 0.4

            return scoreA < scoreB
        }.prefix(limit).map(\.result)
    }

}

struct GeocodingResult: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: GeocodingResult, rhs: GeocodingResult) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum GeocodingError: Error, LocalizedError {
    case apiError

    var errorDescription: String? {
        "Geocoding request failed."
    }
}
