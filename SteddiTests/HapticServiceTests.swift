import Testing
import Foundation
@testable import Steddi

@Suite("HapticService per-event intensity", .serialized)
@MainActor
final class HapticServiceIntensityTests {

    private let suiteName = "HapticServiceTests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Defaults

    @Test("Unset events return their Dynamic defaults")
    func unsetReturnsDynamicDefaults() {
        let service = HapticService(defaults: defaults)

        for event in HapticEvent.allCases {
            #expect(service.intensity(for: event) == event.dynamicDefault)
        }
    }

    @Test("Dynamic profile matches the tuned constants")
    func dynamicProfileValues() {
        #expect(HapticEvent.turnApproaching.dynamicDefault == 0.4)
        #expect(HapticEvent.rerouteSuggestion.dynamicDefault == 0.6)
        #expect(HapticEvent.arrival.dynamicDefault == 1.0)
        #expect(HapticEvent.uiToggle.dynamicDefault == 0.2)
        #expect(HapticEvent.alert.dynamicDefault == 0.7)
    }

    @Test("Dynamic defaults are all within 0...1")
    func dynamicDefaultsInRange() {
        for event in HapticEvent.allCases {
            #expect(event.dynamicDefault >= 0)
            #expect(event.dynamicDefault <= 1)
        }
    }

    // MARK: - Persistence

    @Test("Set intensity reads back")
    func setIntensityReadsBack() {
        let service = HapticService(defaults: defaults)

        service.setIntensity(0.85, for: .turnApproaching)

        #expect(service.intensity(for: .turnApproaching) == 0.85)
    }

    @Test("Set intensity persists across service instances")
    func persistsAcrossInstances() {
        HapticService(defaults: defaults).setIntensity(0.45, for: .arrival)

        let reloaded = HapticService(defaults: defaults)

        #expect(reloaded.intensity(for: .arrival) == 0.45)
    }

    @Test("Setting one event does not affect others")
    func setIsScopedToEvent() {
        let service = HapticService(defaults: defaults)

        service.setIntensity(0.1, for: .uiToggle)

        #expect(service.intensity(for: .alert) == HapticEvent.alert.dynamicDefault)
        #expect(service.intensity(for: .rerouteSuggestion) == HapticEvent.rerouteSuggestion.dynamicDefault)
    }

    @Test("Zero is a valid stored intensity, not a fallback to default")
    func zeroIsStored() {
        let service = HapticService(defaults: defaults)

        service.setIntensity(0, for: .arrival)

        #expect(service.intensity(for: .arrival) == 0)
    }

    // MARK: - Clamping

    @Test("Write above 1 clamps to 1")
    func writeClampsHigh() {
        let service = HapticService(defaults: defaults)

        service.setIntensity(1.7, for: .alert)

        #expect(service.intensity(for: .alert) == 1.0)
    }

    @Test("Write below 0 clamps to 0")
    func writeClampsLow() {
        let service = HapticService(defaults: defaults)

        service.setIntensity(-0.4, for: .alert)

        #expect(service.intensity(for: .alert) == 0)
    }

    @Test("Out-of-range stored value clamps on read")
    func readClampsStoredValue() {
        defaults.set(2.5, forKey: "steddi.haptic.\(HapticEvent.turnApproaching.rawValue)")

        let service = HapticService(defaults: defaults)

        #expect(service.intensity(for: .turnApproaching) == 1.0)
    }

    // MARK: - Reset

    @Test("Reset restores Dynamic defaults for all events")
    func resetRestoresDefaults() {
        let service = HapticService(defaults: defaults)
        for event in HapticEvent.allCases {
            service.setIntensity(0.99, for: event)
        }

        service.resetIntensitiesToDynamicDefaults()

        for event in HapticEvent.allCases {
            #expect(service.intensity(for: event) == event.dynamicDefault)
        }
    }
}
