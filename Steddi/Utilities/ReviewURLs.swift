import Foundation
import CoreLocation

/// Builds link-out URLs to third-party review surfaces (Yelp, Google Maps,
/// Apple Maps) for a pinned place. No API, no embed — these open in the
/// browser / Maps app via `UIApplication.shared.open`. Place names are
/// percent-encoded so special characters (`& % ? # /` spaces) survive.
enum ReviewURLs {

    /// Characters allowed in a query-component value. We start from
    /// `urlQueryAllowed` and remove the sub-delims that would otherwise be
    /// read as structure inside a query string, so `&`, `?`, `#`, `=`, `+`
    /// in a place name get escaped rather than splitting the URL.
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&?#=+/")
        return set
    }()

    /// Percent-encode a free-text value for safe placement in a query string.
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    }

    /// Format a coordinate component with fixed precision so URLs are stable
    /// and don't carry float noise.
    private static func coord(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    /// Yelp search scoped to the place name near a coordinate.
    /// `yelp.com/search?find_desc={name}&find_loc={lat},{lon}`
    static func yelpSearchURL(name: String, latitude: Double, longitude: Double) -> URL? {
        let desc = encode(name)
        let loc = "\(coord(latitude))%2C\(coord(longitude))" // %2C == encoded comma
        let string = "https://www.yelp.com/search?find_desc=\(desc)&find_loc=\(loc)"
        return URL(string: string)
    }

    /// Google Maps search for the place name at a coordinate.
    /// `maps.google.com/maps/search/?api=1&query={name}` with the coordinate
    /// appended so the result is anchored to the right location.
    static func googleMapsURL(name: String, latitude: Double, longitude: Double) -> URL? {
        let query = encode("\(name) \(coord(latitude)),\(coord(longitude))")
        let string = "https://www.google.com/maps/search/?api=1&query=\(query)"
        return URL(string: string)
    }

    /// Apple Maps query for the place name at a coordinate.
    /// `maps.apple.com/?q={name}&ll={lat},{lon}`
    static func appleMapsURL(name: String, latitude: Double, longitude: Double) -> URL? {
        let q = encode(name)
        let ll = "\(coord(latitude))%2C\(coord(longitude))"
        let string = "https://maps.apple.com/?q=\(q)&ll=\(ll)"
        return URL(string: string)
    }

    // Coordinate-typed convenience overloads.

    static func yelpSearchURL(name: String, coordinate: CLLocationCoordinate2D) -> URL? {
        yelpSearchURL(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    static func googleMapsURL(name: String, coordinate: CLLocationCoordinate2D) -> URL? {
        googleMapsURL(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    static func appleMapsURL(name: String, coordinate: CLLocationCoordinate2D) -> URL? {
        appleMapsURL(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
