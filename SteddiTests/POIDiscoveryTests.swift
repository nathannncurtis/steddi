import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - ReviewURLs

@Suite("ReviewURLs")
struct ReviewURLsTests {

    @Test("Yelp URL encodes name and embeds coordinate")
    func yelpBasic() throws {
        let url = try #require(ReviewURLs.yelpSearchURL(name: "Blue Bottle", latitude: 37.123456, longitude: -122.654321))
        let s = url.absoluteString
        #expect(s.hasPrefix("https://www.yelp.com/search?"))
        #expect(s.contains("find_desc=Blue%20Bottle"))
        // Coordinate joined with an encoded comma at fixed precision.
        #expect(s.contains("find_loc=37.123456%2C-122.654321"))
    }

    @Test("Yelp URL percent-encodes structural characters in the name")
    func yelpSpecialChars() throws {
        let url = try #require(ReviewURLs.yelpSearchURL(name: "Tom & Jerry's #1 Café?", latitude: 0, longitude: 0))
        let s = url.absoluteString
        // The raw ampersand/hash/question mark must not appear unescaped in the
        // query value — otherwise they'd split the URL.
        #expect(!s.contains("& Jerry"))
        #expect(!s.contains("#1"))
        #expect(s.contains("%26")) // &
        #expect(s.contains("%23")) // #
        #expect(s.contains("%3F")) // ?
        // Still a valid, parseable URL.
        #expect(URL(string: s) != nil)
    }

    @Test("Google Maps URL uses api=1 and encodes the query")
    func googleBasic() throws {
        let url = try #require(ReviewURLs.googleMapsURL(name: "Joe's Diner", latitude: 40.0, longitude: -73.5))
        let s = url.absoluteString
        #expect(s.hasPrefix("https://www.google.com/maps/search/?api=1&query="))
        // Apostrophe is a legal query character and stays literal; space is %20.
        #expect(s.contains("Joe's%20Diner"))
        #expect(s.contains("40.000000"))
    }

    @Test("Apple Maps URL carries q and ll")
    func appleBasic() throws {
        let url = try #require(ReviewURLs.appleMapsURL(name: "Pier 39", latitude: 37.808, longitude: -122.409))
        let s = url.absoluteString
        #expect(s.hasPrefix("https://maps.apple.com/?q="))
        #expect(s.contains("q=Pier%2039"))
        #expect(s.contains("ll=37.808000%2C-122.409000"))
    }

    @Test("Coordinate overloads match the scalar builders")
    func coordinateOverloads() throws {
        let coord = CLLocationCoordinate2D(latitude: 12.5, longitude: -34.25)
        let a = try #require(ReviewURLs.yelpSearchURL(name: "X", coordinate: coord))
        let b = try #require(ReviewURLs.yelpSearchURL(name: "X", latitude: 12.5, longitude: -34.25))
        #expect(a.absoluteString == b.absoluteString)
    }

    @Test("Spaces in name become %20, not +")
    func spacesEncoding() throws {
        let url = try #require(ReviewURLs.yelpSearchURL(name: "a b c", latitude: 1, longitude: 2))
        #expect(url.absoluteString.contains("a%20b%20c"))
        #expect(!url.absoluteString.contains("a+b+c"))
    }
}

// MARK: - PlaceCategory

@Suite("PlaceCategory")
struct PlaceCategoryTests {

    @Test("category(for:) maps known keys and falls back to other")
    func lookup() {
        #expect(PlaceCategory.category(for: "home") == .home)
        #expect(PlaceCategory.category(for: "gas_station") == .gasStation)
        #expect(PlaceCategory.category(for: "") == .other)
        #expect(PlaceCategory.category(for: "not_a_real_category") == .other)
    }

    @Test("Every category has a non-empty symbol and display name")
    func metadata() {
        for category in PlaceCategory.allCategories {
            #expect(!category.symbol.isEmpty)
            #expect(!category.displayName.isEmpty)
            #expect(category.key == category.rawValue)
        }
    }

    @Test("gas_station key uses underscore form")
    func gasStationKey() {
        #expect(PlaceCategory.gasStation.key == "gas_station")
    }

    @Test("iconOptions promotes the category symbol to the front, de-duplicated")
    func iconOptionsLead() {
        let options = PlaceCategory.iconOptions(for: .gym)
        #expect(options.first?.symbol == PlaceCategory.gym.symbol)
        // No duplicate of the lead symbol later in the list.
        let leadCount = options.filter { $0.symbol == PlaceCategory.gym.symbol }.count
        #expect(leadCount == 1)
    }

    @Test("iconOptions(for: nil) returns the full set unmodified")
    func iconOptionsNil() {
        let options = PlaceCategory.iconOptions(for: nil)
        #expect(options.count == PlaceCategory.allCases.count)
    }
}

// MARK: - Category Migration

@Suite("PinnedLocationCategoryMigration")
struct CategoryMigrationTests {

    @Test("Known icons infer the right category key")
    func knownIcons() {
        #expect(PinnedLocationCategoryMigration.inferredKey(forIcon: "house.fill") == "home")
        #expect(PinnedLocationCategoryMigration.inferredKey(forIcon: "building.2.fill") == "work")
        #expect(PinnedLocationCategoryMigration.inferredKey(forIcon: "figure.run") == "gym")
        #expect(PinnedLocationCategoryMigration.inferredKey(forIcon: "cart.fill") == "grocery")
        #expect(PinnedLocationCategoryMigration.inferredKey(forIcon: "cup.and.saucer.fill") == "cafe")
        #expect(PinnedLocationCategoryMigration.inferredKey(forIcon: "fork.knife") == "restaurant")
        #expect(PinnedLocationCategoryMigration.inferredKey(forIcon: "cross.fill") == "hospital")
        #expect(PinnedLocationCategoryMigration.inferredKey(forIcon: "book.fill") == "school")
        #expect(PinnedLocationCategoryMigration.inferredKey(forIcon: "airplane") == "airport")
    }

    @Test("Unknown icon falls back to other")
    func unknownIcon() {
        #expect(PinnedLocationCategoryMigration.inferredKey(forIcon: "sparkles") == "other")
        #expect(PinnedLocationCategoryMigration.inferredKey(forIcon: "") == "other")
    }

    @Test("mappin default icon maps to other")
    func defaultIcon() {
        #expect(PinnedLocationCategoryMigration.inferredKey(forIcon: "mappin.circle.fill") == "other")
    }

    @Test("Inferred key always resolves back to a valid category")
    func roundTrip() {
        let icons = ["house.fill", "building.2.fill", "figure.run", "sparkles", "airplane", ""]
        for icon in icons {
            let key = PinnedLocationCategoryMigration.inferredKey(forIcon: icon)
            // No key should resolve to a non-other fallback unexpectedly — but
            // every key must be a real category.
            #expect(PlaceCategory(rawValue: key) != nil)
        }
    }
}

// MARK: - PinnedLocation model

@Suite("PinnedLocation category")
struct PinnedLocationCategoryTests {

    @Test("New pin defaults to other category")
    func defaultCategory() {
        let pin = PinnedLocation(name: "X", latitude: 1, longitude: 2)
        #expect(pin.category == PlaceCategory.other.key)
        #expect(pin.resolvedCategory == .other)
    }

    @Test("Explicit category is stored and resolved")
    func explicitCategory() {
        let pin = PinnedLocation(name: "Gym", latitude: 1, longitude: 2, category: PlaceCategory.gym.key)
        #expect(pin.category == "gym")
        #expect(pin.resolvedCategory == .gym)
    }

    @Test("Empty stored category resolves to other (legacy pin)")
    func legacyEmpty() {
        let pin = PinnedLocation(name: "Legacy", latitude: 1, longitude: 2)
        pin.category = ""
        #expect(pin.resolvedCategory == .other)
    }
}
