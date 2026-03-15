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
        limit: Int = 5
    ) async throws -> [GeocodingResult] {
        guard !query.isEmpty else { return [] }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query

        var components = URLComponents(string: "https://api.mapbox.com/search/geocode/v6/forward")!
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "types", value: "address,place,poi,neighborhood"),
        ]

        if let prox = proximity {
            queryItems.append(URLQueryItem(name: "proximity", value: "\(prox.longitude),\(prox.latitude)"))
        }

        components.queryItems = queryItems

        let (data, response) = try await session.data(from: components.url!)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GeocodingError.apiError
        }

        let result = try JSONDecoder().decode(GeocodingResponse.self, from: data)

        return result.features.compactMap { feature in
            guard let coords = feature.geometry?.coordinates, coords.count >= 2 else { return nil }
            return GeocodingResult(
                name: feature.properties.name ?? feature.properties.full_address ?? "Unknown",
                address: feature.properties.full_address ?? feature.properties.place_formatted ?? "",
                coordinate: CLLocationCoordinate2D(latitude: coords[1], longitude: coords[0])
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

// MARK: - API Response

private struct GeocodingResponse: Decodable {
    let features: [Feature]

    struct Feature: Decodable {
        let properties: Properties
        let geometry: Geometry?
    }

    struct Properties: Decodable {
        let name: String?
        let full_address: String?
        let place_formatted: String?
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
