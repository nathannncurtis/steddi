import Foundation
import CoreLocation

/// Wraps Mapbox Geocoding API for place search (forward geocoding).
final class GeocodingService {
    private let accessToken: String
    private let session: URLSession

    init(accessToken: String, session: URLSession = .shared) {
        self.accessToken = accessToken
        self.session = session
    }

    /// Search for places matching a query string.
    /// Biases results toward the given proximity coordinate.
    func search(
        query: String,
        proximity: CLLocationCoordinate2D? = nil,
        limit: Int = 10
    ) async throws -> [GeocodingResult] {
        guard !query.isEmpty else { return [] }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query

        var components = URLComponents(string: "https://api.mapbox.com/search/searchbox/v1/forward")!
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "types", value: "poi,address,street,place"),
        ]

        if let prox = proximity {
            queryItems.append(URLQueryItem(name: "proximity", value: "\(prox.longitude),\(prox.latitude)"))
        }

        components.queryItems = queryItems

        let (data, response) = try await session.data(from: components.url!)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GeocodingError.apiError
        }

        let result = try JSONDecoder().decode(SearchBoxResponse.self, from: data)

        return result.features.compactMap { feature in
            // Search Box v1: coordinates in geometry (GeoJSON) or properties.coordinates
            let coordinate: CLLocationCoordinate2D?
            if let geom = feature.geometry?.coordinates, geom.count >= 2 {
                coordinate = CLLocationCoordinate2D(latitude: geom[1], longitude: geom[0])
            } else if let propCoords = feature.properties.coordinates {
                coordinate = CLLocationCoordinate2D(latitude: propCoords.latitude, longitude: propCoords.longitude)
            } else {
                coordinate = nil
            }

            guard let coord = coordinate else { return nil }

            return GeocodingResult(
                name: feature.properties.name_preferred ?? feature.properties.name ?? feature.properties.full_address ?? "Unknown",
                address: feature.properties.full_address ?? feature.properties.place_formatted ?? "",
                coordinate: coord
            )
        }
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

// MARK: - Search Box v1 API Response

private struct SearchBoxResponse: Decodable {
    let features: [Feature]

    struct Feature: Decodable {
        let properties: Properties
        let geometry: Geometry?
    }

    struct Properties: Decodable {
        let name: String?
        let name_preferred: String?
        let full_address: String?
        let place_formatted: String?
        let coordinates: Coordinates?
    }

    struct Coordinates: Decodable {
        let longitude: Double
        let latitude: Double
    }

    struct Geometry: Decodable {
        let coordinates: [Double]
    }
}

enum GeocodingError: Error, LocalizedError {
    case apiError

    var errorDescription: String? {
        "Geocoding request failed."
    }
}
