import Testing
import Foundation
@testable import Steddi

private func freshDefaults() -> UserDefaults {
    let name = "notifcentertest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("CommuteNotificationCenter identifiers & deep link")
struct NotificationIdentifierTests {

    @Test("Identifier is stable per commute+direction")
    func stableIdentifier() {
        let id = UUID()
        let a = CommuteNotificationCenter.identifier(commuteId: id, direction: .originToDestination)
        let b = CommuteNotificationCenter.identifier(commuteId: id, direction: .originToDestination)
        #expect(a == b)
        #expect(a.hasPrefix(CommuteNotificationCenter.identifierPrefix))
    }

    @Test("Different directions get distinct identifiers")
    func directionDistinct() {
        let id = UUID()
        let toDest = CommuteNotificationCenter.identifier(commuteId: id, direction: .originToDestination)
        let toOrigin = CommuteNotificationCenter.identifier(commuteId: id, direction: .destinationToOrigin)
        #expect(toDest != toOrigin)
    }

    @Test("Start-commute deep link reuses steddi://navigate scheme")
    func deepLinkScheme() {
        let id = UUID()
        let url = CommuteNotificationCenter.startCommuteDeepLink(commuteId: id, direction: .originToDestination)
        #expect(url.scheme == "steddi")
        #expect(url.host == "navigate")
        #expect(url.absoluteString.contains("commuteId=\(id.uuidString)"))
        #expect(url.absoluteString.contains("direction=originToDestination"))
    }
}

@Suite("CommuteNotificationCenter cooldown bookkeeping")
struct NotificationCooldownTests {

    @Test("No prior notification returns nil")
    func noPriorNil() {
        let defaults = freshDefaults()
        let nc = CommuteNotificationCenter(defaults: defaults)
        #expect(nc.lastNotificationTime(commuteId: UUID()) == nil)
    }

    @Test("Recorded notification round-trips")
    func recordRoundTrip() {
        let defaults = freshDefaults()
        let nc = CommuteNotificationCenter(defaults: defaults)
        let id = UUID()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        nc.recordNotification(commuteId: id, at: when)
        let read = nc.lastNotificationTime(commuteId: id)
        #expect(read != nil)
        #expect(abs((read ?? .distantPast).timeIntervalSince1970 - when.timeIntervalSince1970) < 1)
    }

    @Test("Cooldown key matches spec format")
    func cooldownKeyFormat() {
        let id = UUID()
        let key = CommuteNotificationCenter.cooldownKey(commuteId: id)
        #expect(key == "steddi.lastCommuteNotificationTime.\(id.uuidString)")
    }

    @Test("Cooldown is isolated per commute")
    func cooldownIsolated() {
        let defaults = freshDefaults()
        let nc = CommuteNotificationCenter(defaults: defaults)
        let a = UUID()
        let b = UUID()
        nc.recordNotification(commuteId: a, at: Date())
        #expect(nc.lastNotificationTime(commuteId: a) != nil)
        #expect(nc.lastNotificationTime(commuteId: b) == nil)
    }
}
