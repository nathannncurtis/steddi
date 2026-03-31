import Foundation
import MapKit
import CoreLocation

/// Parses natural language route descriptions into waypoints.
/// v1: handles highway names, street names, and connectors (to, via, exit at).
/// No ML model required — pure string parsing + geocoding.
final class FuzzyRouteParser {

    /// Parse a route description into a list of waypoint coordinates.
    /// Example: "take the 91 to the 15 north, exit at Main St"
    static func parse(_ input: String, near location: CLLocationCoordinate2D?) async -> [CLLocationCoordinate2D] {
        let segments = tokenize(input)
        var waypoints: [CLLocationCoordinate2D] = []

        for segment in segments {
            if let coord = await geocode(segment, near: location ?? waypoints.last) {
                waypoints.append(coord)
            }
        }

        return waypoints
    }

    /// Break input into location tokens.
    /// Splits on connectors: "to", "via", "then", "exit at", "onto", commas
    private static func tokenize(_ input: String) -> [String] {
        let normalized = input
            .lowercased()
            .replacingOccurrences(of: "take ", with: "")
            .replacingOccurrences(of: "get on ", with: "")
            .replacingOccurrences(of: "merge onto ", with: "")
            .replacingOccurrences(of: "head ", with: "")

        // Split on connectors
        let separators = [" to ", " via ", " then ", " exit at ", " onto ", ",", " and then "]
        var parts = [normalized]
        for sep in separators {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }

        return parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { expandHighwayName($0) }
    }

    /// Expand common highway shorthand: "the 91" → "CA-91", "91 freeway" → "CA-91", "i-10" → "I-10"
    private static func expandHighwayName(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespaces)

        // "the 91" or "91" → "CA-91"
        if let match = s.range(of: #"^the\s+(\d+)$"#, options: .regularExpression) {
            let num = s[match].replacingOccurrences(of: "the ", with: "")
            return "CA-\(num) freeway"
        }

        // "91 freeway" or "91 fwy"
        if let match = s.range(of: #"^(\d+)\s*(freeway|fwy|highway|hwy)$"#, options: .regularExpression) {
            let num = s[s.startIndex..<s.firstIndex(of: " ")!]
            return "CA-\(num) freeway"
        }

        // Just a number like "91"
        if s.allSatisfy({ $0.isNumber }) {
            return "CA-\(s) freeway"
        }

        // "i-10" or "i10"
        s = s.replacingOccurrences(of: #"^i-?(\d+)"#, with: "I-$1", options: .regularExpression)

        // Direction suffixes
        s = s.replacingOccurrences(of: " north", with: "")
            .replacingOccurrences(of: " south", with: "")
            .replacingOccurrences(of: " east", with: "")
            .replacingOccurrences(of: " west", with: "")

        return s
    }

    /// Geocode a location string using MKLocalSearch
    private static func geocode(_ query: String, near: CLLocationCoordinate2D?) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        if let near {
            request.region = MKCoordinateRegion(
                center: near,
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            )
        }

        do {
            let search = MKLocalSearch(request: request)
            let response = try await search.start()
            return response.mapItems.first?.location.coordinate
        } catch {
            return nil
        }
    }
}
