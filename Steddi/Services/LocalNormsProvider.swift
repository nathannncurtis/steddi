import Foundation
import CoreLocation

/// Maps a location to historical temperature norms — 65°F is warm in Anchorage
/// and cool in San Diego, and temperature tinting must know the difference.
///
/// Pragmatic, fully offline strategy: named climate-zone boxes (checked first,
/// they capture coast/desert/mountain microclimates the bands miss), then
/// 10–15° latitude bands with hemisphere-correct seasons, then the national
/// average. All data ships in `TemperatureNorms.json`; no network, no quota.
struct LocalNormsProvider {

    struct Region: Decodable {
        let name: String?
        let latMin: Double
        let latMax: Double
        let lonMin: Double?
        let lonMax: Double?
        /// Monthly typical highs/lows, January-first, exactly 12 entries.
        let highsF: [Double]
        let lowsF: [Double]

        func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
            guard coordinate.latitude >= latMin, coordinate.latitude <= latMax else { return false }
            if let lonMin, let lonMax {
                return coordinate.longitude >= lonMin && coordinate.longitude <= lonMax
            }
            return true
        }

        /// Region with malformed monthly arrays can never be matched against.
        var isUsable: Bool { highsF.count == 12 && lowsF.count == 12 }
    }

    struct Table: Decodable {
        let version: Int
        let zones: [Region]
        let bands: [Region]
    }

    private let table: Table?
    private let calendar: Calendar
    private let now: () -> Date

    init(calendar: Calendar = .current, now: @escaping () -> Date = { Date() }) {
        self.init(table: Self.bundledTable, calendar: calendar, now: now)
    }

    /// Test seam: explicit table (or nil to exercise the last-resort fallback).
    init(table: Table?, calendar: Calendar = .current, now: @escaping () -> Date = { Date() }) {
        self.table = table
        self.calendar = calendar
        self.now = now
    }

    init?(data: Data, calendar: Calendar = .current, now: @escaping () -> Date = { Date() }) {
        guard let table = try? JSONDecoder().decode(Table.self, from: data) else { return nil }
        self.init(table: table, calendar: calendar, now: now)
    }

    // MARK: - Lookups

    /// Typical high for the month (1–12) at a coordinate.
    func getTypicalHigh(at coordinate: CLLocationCoordinate2D, forMonth month: Int) -> Double {
        norm(at: coordinate, month: month).typicalHighF
    }

    /// Typical low for the month (1–12) at a coordinate.
    func getTypicalLow(at coordinate: CLLocationCoordinate2D, forMonth month: Int) -> Double {
        norm(at: coordinate, month: month).typicalLowF
    }

    /// Norm for the current calendar month at a coordinate.
    func getNormForToday(at coordinate: CLLocationCoordinate2D) -> TemperatureNorm {
        norm(at: coordinate, month: calendar.component(.month, from: now()))
    }

    /// Full lookup: climate zones beat latitude bands beat the national average.
    func norm(at coordinate: CLLocationCoordinate2D, month: Int) -> TemperatureNorm {
        let index = min(11, max(0, month - 1))
        guard let table else { return .nationalAverage }

        if let zone = table.zones.first(where: { $0.isUsable && $0.contains(coordinate) }) {
            return TemperatureNorm(typicalHighF: zone.highsF[index], typicalLowF: zone.lowsF[index])
        }
        if let band = table.bands.first(where: { $0.isUsable && $0.contains(coordinate) }) {
            return TemperatureNorm(typicalHighF: band.highsF[index], typicalLowF: band.lowsF[index])
        }
        return .nationalAverage
    }

    // MARK: - Bundled data

    /// Decoded once per process; the table is a few KB of value types.
    static let bundledTable: Table? = {
        guard let url = Bundle(for: NormsBundleToken.self).url(forResource: "TemperatureNorms", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Table.self, from: data)
    }()
}

/// Anchor for bundle resolution — works from the app and from unit tests,
/// where Bundle.main is the test runner.
private final class NormsBundleToken {}
