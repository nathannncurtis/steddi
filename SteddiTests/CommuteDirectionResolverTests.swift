import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import Steddi

@Suite("CommuteDirectionResolver", .serialized)
@MainActor
struct CommuteDirectionResolverTests {

    // MARK: - Helpers

    /// Create an in-memory SwiftData container and return a context for making model objects.
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Commute.self, PinnedLocation.self, Route.self, CommuteTrip.self,
            configurations: config
        )
        return container.mainContext
    }

    /// Create a commute with origin at (lat1, lon1) and destination at (lat2, lon2).
    private func makeCommute(
        context: ModelContext,
        originLat: Double, originLon: Double, originName: String = "Home",
        destLat: Double, destLon: Double, destName: String = "Work"
    ) -> Commute {
        let origin = PinnedLocation(name: originName, latitude: originLat, longitude: originLon)
        let dest = PinnedLocation(name: destName, latitude: destLat, longitude: destLon)
        context.insert(origin)
        context.insert(dest)

        let commute = Commute(name: "Test Commute", origin: origin, destination: dest)
        context.insert(commute)
        return commute
    }

    // MARK: - Proximity Tests

    @Test("Within 152m of origin resolves to originToDestination")
    func nearOriginResolvesConfident() throws {
        let ctx = try makeContext()
        let commute = makeCommute(
            context: ctx,
            originLat: 34.0522, originLon: -118.2437,
            destLat: 34.1522, destLon: -118.1437
        )

        // Location ~10m from origin
        let location = CLLocation(latitude: 34.0523, longitude: -118.2437)
        let result = CommuteDirectionResolver.resolve(commute: commute, currentLocation: location)

        if case .confident(let direction, _) = result {
            #expect(direction == .originToDestination)
        } else {
            Issue.record("Expected confident originToDestination")
        }
    }

    @Test("Within 152m of destination resolves to destinationToOrigin")
    func nearDestinationResolvesConfident() throws {
        let ctx = try makeContext()
        let commute = makeCommute(
            context: ctx,
            originLat: 34.0522, originLon: -118.2437,
            destLat: 34.1522, destLon: -118.1437
        )

        // Location ~10m from destination
        let location = CLLocation(latitude: 34.1523, longitude: -118.1437)
        let result = CommuteDirectionResolver.resolve(commute: commute, currentLocation: location)

        if case .confident(let direction, _) = result {
            #expect(direction == .destinationToOrigin)
        } else {
            Issue.record("Expected confident destinationToOrigin")
        }
    }

    @Test("Far from both endpoints resolves to ambiguous")
    func farFromBothIsAmbiguous() throws {
        let ctx = try makeContext()
        let commute = makeCommute(
            context: ctx,
            originLat: 34.0522, originLon: -118.2437,
            destLat: 34.1522, destLon: -118.1437
        )

        // Location far from both endpoints (~5km away)
        let location = CLLocation(latitude: 34.10, longitude: -118.20)
        let result = CommuteDirectionResolver.resolve(commute: commute, currentLocation: location)

        if case .ambiguous = result {
            // expected
        } else {
            Issue.record("Expected ambiguous result when far from both endpoints")
        }
    }

    // MARK: - Schedule Tests

    @Test("Matching schedule to destination resolves confidently")
    func scheduleMatchesOriginToDestination() throws {
        let ctx = try makeContext()
        let commute = makeCommute(
            context: ctx,
            originLat: 34.0522, originLon: -118.2437,
            destLat: 34.1522, destLon: -118.1437
        )

        // Configure schedule: weekdays (Mon=2..Fri=6) 6-10 → originToDestination
        commute.scheduleToDestDays = "2,3,4,5,6"
        commute.scheduleToDestStartHour = 6
        commute.scheduleToDestEndHour = 10

        // Far from both endpoints but matching schedule
        let location = CLLocation(latitude: 34.10, longitude: -118.20)

        // Create a Monday at 8 AM
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 23 // Monday
        components.hour = 8
        let monday8am = Calendar.current.date(from: components)!

        let result = CommuteDirectionResolver.resolve(
            commute: commute,
            currentLocation: location,
            now: monday8am
        )

        if case .confident(let direction, _) = result {
            #expect(direction == .originToDestination)
        } else {
            Issue.record("Expected confident originToDestination from schedule")
        }
    }

    @Test("Matching schedule to origin resolves confidently")
    func scheduleMatchesDestinationToOrigin() throws {
        let ctx = try makeContext()
        let commute = makeCommute(
            context: ctx,
            originLat: 34.0522, originLon: -118.2437,
            destLat: 34.1522, destLon: -118.1437
        )

        // Configure schedule: weekdays 15-19 → destinationToOrigin
        commute.scheduleToOriginDays = "2,3,4,5,6"
        commute.scheduleToOriginStartHour = 15
        commute.scheduleToOriginEndHour = 19

        let location = CLLocation(latitude: 34.10, longitude: -118.20)

        // Tuesday at 5 PM
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 24 // Tuesday
        components.hour = 17
        let tuesday5pm = Calendar.current.date(from: components)!

        let result = CommuteDirectionResolver.resolve(
            commute: commute,
            currentLocation: location,
            now: tuesday5pm
        )

        if case .confident(let direction, _) = result {
            #expect(direction == .destinationToOrigin)
        } else {
            Issue.record("Expected confident destinationToOrigin from schedule")
        }
    }

    @Test("Non-matching schedule falls through to ambiguous")
    func scheduleDoesNotMatch() throws {
        let ctx = try makeContext()
        let commute = makeCommute(
            context: ctx,
            originLat: 34.0522, originLon: -118.2437,
            destLat: 34.1522, destLon: -118.1437
        )

        // Configure schedule for weekdays 6-10 only
        commute.scheduleToDestDays = "2,3,4,5,6"
        commute.scheduleToDestStartHour = 6
        commute.scheduleToDestEndHour = 10

        let location = CLLocation(latitude: 34.10, longitude: -118.20)

        // Saturday at 8 AM — schedule says weekdays only
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 21 // Saturday
        components.hour = 8
        let saturday8am = Calendar.current.date(from: components)!

        let result = CommuteDirectionResolver.resolve(
            commute: commute,
            currentLocation: location,
            now: saturday8am
        )

        if case .ambiguous = result {
            // expected
        } else {
            Issue.record("Expected ambiguous when schedule does not match")
        }
    }

    // MARK: - Missing Endpoints

    @Test("No origin returns ambiguous")
    func noOriginIsAmbiguous() throws {
        let ctx = try makeContext()
        let dest = PinnedLocation(name: "Work", latitude: 34.1522, longitude: -118.1437)
        ctx.insert(dest)

        let commute = Commute(name: "Test", origin: nil, destination: dest)
        ctx.insert(commute)

        let location = CLLocation(latitude: 34.0522, longitude: -118.2437)
        let result = CommuteDirectionResolver.resolve(commute: commute, currentLocation: location)

        if case .ambiguous = result {
            // expected
        } else {
            Issue.record("Expected ambiguous when origin is nil")
        }
    }

    @Test("No destination returns ambiguous")
    func noDestinationIsAmbiguous() throws {
        let ctx = try makeContext()
        let origin = PinnedLocation(name: "Home", latitude: 34.0522, longitude: -118.2437)
        ctx.insert(origin)

        let commute = Commute(name: "Test", origin: origin, destination: nil)
        ctx.insert(commute)

        let location = CLLocation(latitude: 34.0522, longitude: -118.2437)
        let result = CommuteDirectionResolver.resolve(commute: commute, currentLocation: location)

        if case .ambiguous = result {
            // expected
        } else {
            Issue.record("Expected ambiguous when destination is nil")
        }
    }

    @Test("No origin and no destination returns ambiguous")
    func noBothEndpointsIsAmbiguous() throws {
        let ctx = try makeContext()
        let commute = Commute(name: "Test", origin: nil, destination: nil)
        ctx.insert(commute)

        let location = CLLocation(latitude: 34.0522, longitude: -118.2437)
        let result = CommuteDirectionResolver.resolve(commute: commute, currentLocation: location)

        if case .ambiguous = result {
            // expected
        } else {
            Issue.record("Expected ambiguous when both endpoints are nil")
        }
    }

    // MARK: - Confident result carries correct destination name

    @Test("Confident result at origin carries destination name")
    func confidentAtOriginCarriesDestName() throws {
        let ctx = try makeContext()
        let commute = makeCommute(
            context: ctx,
            originLat: 34.0522, originLon: -118.2437, originName: "Home",
            destLat: 34.1522, destLon: -118.1437, destName: "Work"
        )

        let location = CLLocation(latitude: 34.0522, longitude: -118.2437)
        let result = CommuteDirectionResolver.resolve(commute: commute, currentLocation: location)

        if case .confident(_, let name) = result {
            #expect(name == "Work")
        } else {
            Issue.record("Expected confident result")
        }
    }

    @Test("Confident result at destination carries origin name")
    func confidentAtDestCarriesOriginName() throws {
        let ctx = try makeContext()
        let commute = makeCommute(
            context: ctx,
            originLat: 34.0522, originLon: -118.2437, originName: "Home",
            destLat: 34.1522, destLon: -118.1437, destName: "Work"
        )

        let location = CLLocation(latitude: 34.1522, longitude: -118.1437)
        let result = CommuteDirectionResolver.resolve(commute: commute, currentLocation: location)

        if case .confident(_, let name) = result {
            #expect(name == "Home")
        } else {
            Issue.record("Expected confident result")
        }
    }
}
