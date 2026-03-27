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

        let parsed = response.mapItems.prefix(limit).enumerated().map { (index, mapItem) -> (result: GeocodingResult, apiRank: Int) in
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

        // Re-rank by combined relevance + proximity score
        guard let prox = proximity else {
            return parsed.map(\.result)
        }

        let userLocation = CLLocation(latitude: prox.latitude, longitude: prox.longitude)

        return parsed.sorted { a, b in
            let distA = userLocation.distance(from: CLLocation(latitude: a.result.coordinate.latitude, longitude: a.result.coordinate.longitude))
            let distB = userLocation.distance(from: CLLocation(latitude: b.result.coordinate.latitude, longitude: b.result.coordinate.longitude))

            // Combined score: API relevance (lower rank = more relevant) + distance penalty
            // Normalize distance to ~0-1 range (50km = 1.0)
            let distScoreA = min(distA / 50_000, 1.0)
            let distScoreB = min(distB / 50_000, 1.0)

            // API rank normalized to 0-1
            let relevanceA = Double(a.apiRank) / max(Double(parsed.count), 1.0)
            let relevanceB = Double(b.apiRank) / max(Double(parsed.count), 1.0)

            // Weight: 60% proximity, 40% relevance
            let scoreA = distScoreA * 0.6 + relevanceA * 0.4
            let scoreB = distScoreB * 0.6 + relevanceB * 0.4

            return scoreA < scoreB
        }.map(\.result)
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
