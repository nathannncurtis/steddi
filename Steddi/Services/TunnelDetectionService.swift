import Foundation
import CoreLocation
import Observation

/// Tunnel position relative to the driver, as far as Steddi can tell.
enum TunnelStatus: Equatable {
    case outdoor
    case inTunnel
    /// No OSM data and no decisive GPS signal — treated as outdoor for theming.
    case indeterminate
}

/// A tunnel way pulled from OSM. Reuses `SpeedLimitPoint` so geometry decodes
/// straight off Overpass `out geom` output, same as OSMSpeedLimitService.
struct TunnelWay: Codable {
    let wayID: Int
    let geometry: [SpeedLimitPoint]
}

/// Detects tunnel entry/exit from two signals: OSM `tunnel=yes` ways along the
/// route (Overpass, prefetched once per route, cached in memory) and GPS
/// accuracy degradation streaks. Publishes a fade progress for the theme:
/// entry ramps sharp (1s — immediate feedback as signal dies), exit fades slow
/// (5s — GPS hiccups must not flicker the theme).
@Observable
@MainActor
final class TunnelDetectionService {
    static let shared = TunnelDetectionService()

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private(set) var status: TunnelStatus = .outdoor
    private(set) var transitionProgress: Double = 0
    private(set) var loadedRouteKey: String?
    private(set) var isPrefetching = false

    private let transport: Transport
    private let now: () -> Date
    /// Where progress lands — ThemeEngine in production, a probe in tests.
    private let apply: (Double, Bool) -> Void

    /// Per-route cache: route key → tunnel ways. Tunnels are sparse, payloads
    /// tiny; memory is the right cache tier for a single drive.
    private var routeCache: [String: [TunnelWay]] = [:]
    private var segments: [TunnelSegment] = []

    private var prefetchGeneration = 0

    // Fade state machine.
    private enum Phase { case idle, entering, inside, exiting }
    private var phase: Phase = .idle
    private var phaseChangedAt: Date?
    private var progressAtChange: Double = 0

    /// Consecutive location fixes with degraded accuracy.
    private var weakSignalStreak = 0
    /// Most recent fix timestamp processed. Both LocationService and the
    /// navigation loop forward fixes — usually the same one — so each fix
    /// is processed exactly once no matter how many feeds deliver it.
    private var lastFixTimestamp: Date?
    /// Ground speed at the last trustworthy fix. The blind heuristic (weak
    /// streak with no OSM data) only arms when the driver was actually moving
    /// before the signal died — a phone indoors loses accuracy at zero speed.
    private var lastGoodSpeedMPS: Double = 0
    /// Fix timestamp at which the current unbroken weak-signal streak began —
    /// the clock for the blind-latch time-decay. Reset to nil on any non-weak
    /// fix (which also clears `weakSignalStreak`). The blind arm has only a
    /// fix-QUALITY escape (a good fix flips `detected` false); deep underground
    /// or in a long urban-canyon dropout a good fix never arrives, so without a
    /// time escape the dark theme would pin indefinitely. After
    /// `blindLatchMaxSeconds` of sustained degradation with no good fix and no
    /// geometric tunnel signal, we expire `lastGoodSpeedMPS` so the blind arm
    /// disarms and the normal slow exit fade reverts the theme. Genuine short
    /// tunnels exit well inside this window (signal returns → good fix → fade).
    private var weakStreakStartedAt: Date?

    init(
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        now: @escaping () -> Date = { Date() },
        apply: ((Double, Bool) -> Void)? = nil
    ) {
        self.transport = transport
        self.now = now
        self.apply = apply ?? { progress, detected in
            ThemeEngine.shared.setTunnel(progress: progress, isDetected: detected)
        }
    }

    // MARK: - Prefetch (route start)

    /// Fetch tunnel ways within a 500m corridor of the route. One POST per
    /// route, cached in memory; failures are silent (no tunnels ≠ broken UI).
    func prefetch(for polyline: [CLLocationCoordinate2D], routeKey: String) async {
        guard polyline.count >= 2 else { return }
        if let cached = routeCache[routeKey] {
            install(ways: cached, routeKey: routeKey)
            return
        }

        prefetchGeneration += 1
        let generation = prefetchGeneration
        isPrefetching = true
        defer {
            if generation == prefetchGeneration { isPrefetching = false }
        }

        let query = await Task.detached(priority: .utility) {
            let sampled = OSMSpeedLimitService.downsample(
                polyline,
                tolerance: Tuning.downsampleToleranceMeters,
                maxPoints: Tuning.maxQueryPoints
            )
            return Self.overpassQuery(for: sampled)
        }.value

        guard let ways = await fetch(query: query), generation == prefetchGeneration else { return }
        routeCache[routeKey] = ways
        if routeCache.count > Tuning.maxCachedRoutes {
            // Drop an arbitrary stale entry — only the active route matters.
            if let staleKey = routeCache.keys.first(where: { $0 != routeKey }) {
                routeCache.removeValue(forKey: staleKey)
            }
        }
        install(ways: ways, routeKey: routeKey)
    }

    private func install(ways: [TunnelWay], routeKey: String) {
        segments = Self.buildSegments(from: ways)
        loadedRouteKey = routeKey
    }

    /// Test seam: install tunnel geometry without a network round-trip.
    func loadTunnelWays(_ ways: [TunnelWay], routeKey: String) {
        routeCache[routeKey] = ways
        install(ways: ways, routeKey: routeKey)
    }

    /// Test seam: the blind-latch decay window, so the decay test drives the
    /// clock past the real bound without hardcoding it (keeps `Tuning` private).
    nonisolated static var blindLatchMaxSecondsForTesting: TimeInterval { Tuning.blindLatchMaxSeconds }

    func clearRoute() {
        segments = []
        loadedRouteKey = nil
        resetDetection()
    }

    private func resetDetection() {
        phase = .idle
        phaseChangedAt = nil
        progressAtChange = 0
        weakSignalStreak = 0
        weakStreakStartedAt = nil
        lastFixTimestamp = nil
        lastGoodSpeedMPS = 0
        status = .outdoor
        transitionProgress = 0
        apply(0, false)
    }

    // MARK: - Status checks

    /// Async point check: local geometry when loaded, otherwise a one-shot
    /// Overpass probe around the coordinate. Network failure (2s timeout per
    /// mirror) answers `.indeterminate` — callers treat that as outdoor.
    func checkTunnelStatus(
        atCoord coordinate: CLLocationCoordinate2D,
        alongRoute routeKey: String? = nil
    ) async -> TunnelStatus {
        if let routeKey, routeKey == loadedRouteKey || routeCache[routeKey] != nil {
            let ways = routeCache[routeKey] ?? []
            let segments = loadedRouteKey == routeKey ? self.segments : Self.buildSegments(from: ways)
            return Self.isInside(coordinate, segments: segments) ? .inTunnel : .outdoor
        }
        if !segments.isEmpty {
            return Self.isInside(coordinate, segments: segments) ? .inTunnel : .outdoor
        }
        let query = Self.overpassQuery(for: [coordinate])
        guard let ways = await fetch(query: query) else { return .indeterminate }
        let probed = Self.buildSegments(from: ways)
        return Self.isInside(coordinate, segments: probed) ? .inTunnel : .outdoor
    }

    /// Per-fix detection driving the fade. Called from the navigation loop
    /// (~1/sec); each call recomputes progress and pushes it to the engine.
    func updateLocation(_ location: CLLocation) {
        if let lastFixTimestamp, location.timestamp <= lastFixTimestamp { return }
        lastFixTimestamp = location.timestamp

        let accuracy = location.horizontalAccuracy
        let weakSignal = accuracy < 0 || accuracy > Tuning.weakAccuracyMeters
        if weakSignal {
            weakSignalStreak += 1
            if weakStreakStartedAt == nil { weakStreakStartedAt = location.timestamp }
        } else {
            weakSignalStreak = 0
            weakStreakStartedAt = nil
            if location.speed >= 0 { lastGoodSpeedMPS = location.speed }
        }

        let coordinate = location.coordinate
        let geometricallyInside = Self.isInside(coordinate, segments: segments)
        let nearTunnel = geometricallyInside
            || Self.isNear(coordinate, segments: segments, radius: Tuning.portalProximityMeters)

        // Time-decay the BLIND latch so a long reception dropout that isn't a
        // tunnel (underground garage at trip's end, urban canyon, dead-zone)
        // can't pin the dark theme forever. The blind arm's only other escape
        // is a good fix — which never arrives deep underground — so after a
        // bounded duration of UNBROKEN degradation with no geometric tunnel
        // signal we expire the frozen last-good speed; the blind arm then
        // disarms and the normal slow exit fade reverts the theme. Genuine
        // short tunnels clear well inside this window (signal returns → a good
        // fix breaks the streak and resets the clock). Geometric/near-tunnel
        // detection is untouched — neither depends on `lastGoodSpeedMPS`, so a
        // driver actually sitting on OSM tunnel geometry still stays detected.
        if !nearTunnel, let startedAt = weakStreakStartedAt,
           location.timestamp.timeIntervalSince(startedAt) >= Tuning.blindLatchMaxSeconds {
            lastGoodSpeedMPS = 0
        }

        // Signals, strongest first: standing on a tunnel way; signal lost near
        // a known tunnel (GPS coasts stale fixes inside, so proximity + loss
        // beats pure geometry); prolonged loss with no OSM data at all, but
        // only if the driver was moving at road speed before the signal died
        // (and only until the blind latch decays — see above).
        let detected = geometricallyInside
            || (nearTunnel && weakSignalStreak >= Tuning.weakStreakNearTunnel)
            || (segments.isEmpty && weakSignalStreak >= Tuning.weakStreakBlind
                && lastGoodSpeedMPS >= Tuning.blindMinSpeedMPS)

        let timestamp = now()
        switch (detected, phase) {
        case (true, .idle), (true, .exiting):
            progressAtChange = currentProgress(at: timestamp)
            phase = .entering
            phaseChangedAt = timestamp
        case (false, .entering), (false, .inside):
            progressAtChange = currentProgress(at: timestamp)
            phase = .exiting
            phaseChangedAt = timestamp
        default:
            break
        }

        let progress = currentProgress(at: timestamp)
        if phase == .entering && progress >= 1 { phase = .inside }
        if phase == .exiting && progress <= 0 {
            phase = .idle
            phaseChangedAt = nil
        }

        transitionProgress = progress
        status = detected ? .inTunnel : .outdoor
        apply(progress, detected)
    }

    private func currentProgress(at timestamp: Date) -> Double {
        guard let phaseChangedAt else { return phase == .inside ? 1 : 0 }
        let elapsed = timestamp.timeIntervalSince(phaseChangedAt)
        switch phase {
        case .idle:
            return 0
        case .inside:
            return 1
        case .entering:
            return Self.entryProgress(from: progressAtChange, elapsed: elapsed)
        case .exiting:
            return Self.exitProgress(from: progressAtChange, elapsed: elapsed)
        }
    }

    // MARK: - Transition math (pure, testable)

    /// Entry: sharp 1s ramp from wherever the fade currently sits up to 1.
    nonisolated static func entryProgress(from start: Double, elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return start }
        let t = min(1, elapsed / Tuning.entryRampSeconds)
        return start + (1 - start) * t
    }

    /// Exit: slow 5s fade back down — brief GPS hiccups never flicker the theme.
    nonisolated static func exitProgress(from start: Double, elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return start }
        let t = min(1, elapsed / Tuning.exitFadeSeconds)
        return start * (1 - t)
    }

    // MARK: - Geometry

    private nonisolated static func buildSegments(from ways: [TunnelWay]) -> [TunnelSegment] {
        var segments: [TunnelSegment] = []
        for way in ways where way.geometry.count >= 2 {
            for i in 0..<(way.geometry.count - 1) {
                segments.append(TunnelSegment(
                    start: CLLocationCoordinate2D(latitude: way.geometry[i].lat, longitude: way.geometry[i].lon),
                    end: CLLocationCoordinate2D(latitude: way.geometry[i + 1].lat, longitude: way.geometry[i + 1].lon)
                ))
            }
        }
        return segments
    }

    nonisolated static func isInside(_ coordinate: CLLocationCoordinate2D, segments: [TunnelSegment]) -> Bool {
        isNear(coordinate, segments: segments, radius: Tuning.insideRadiusMeters)
    }

    /// Linear scan with a coarse bounding pre-filter — tunnel geometry along a
    /// single route is a handful of segments, no spatial index needed.
    nonisolated static func isNear(
        _ coordinate: CLLocationCoordinate2D,
        segments: [TunnelSegment],
        radius: Double
    ) -> Bool {
        let coarse = radius / 111_000 * 2 + 0.001
        // One degree of longitude spans only 111km·cos(latitude), so a latitude-
        // symmetric pad covers fewer meters in longitude as latitude rises — at
        // high latitudes the longitude window narrows below `radius` and a valid
        // segment just longitudinally beyond a point is wrongly skipped. Scale the
        // longitude pad by 1/cos(latitude) (equirectangular correction, clamped near
        // the poles), mirroring the cosLat handling in OSMSpeedLimitService /
        // RouteGeometry's precise distance paths.
        let cosLat = max(0.2, cos(coordinate.latitude * .pi / 180))
        let coarseLon = coarse / cosLat
        for segment in segments {
            // Full bounding-box pre-filter on BOTH axes, expanded by `coarse`. A
            // latitude-only check would skip long N-S segments whose endpoints are
            // far in latitude from a mid-segment point even though it sits on them.
            let minLat = min(segment.start.latitude, segment.end.latitude) - coarse
            let maxLat = max(segment.start.latitude, segment.end.latitude) + coarse
            let minLon = min(segment.start.longitude, segment.end.longitude) - coarseLon
            let maxLon = max(segment.start.longitude, segment.end.longitude) + coarseLon
            guard coordinate.latitude >= minLat, coordinate.latitude <= maxLat,
                  coordinate.longitude >= minLon, coordinate.longitude <= maxLon else { continue }
            if OSMSpeedLimitService.distanceToSegment(coordinate, segment.start, segment.end) <= radius {
                return true
            }
        }
        return false
    }

    // MARK: - Overpass

    /// Tunnel ways on drivable roads within the corridor. Same clause pattern
    /// as OSMSpeedLimitService, 500m radius, tunnel-tagged highways only.
    nonisolated static func overpassQuery(for points: [CLLocationCoordinate2D]) -> String {
        guard !points.isEmpty else { return "" }
        let filter = #"["highway"]["tunnel"~"^(yes|building_passage)$"]"#

        var clauses: [String] = []
        var start = 0
        repeat {
            let end = min(start + Tuning.maxPointsPerClause, points.count)
            let coords = points[start..<end]
                .map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }
                .joined(separator: ",")
            clauses.append("way(around:\(Tuning.corridorRadiusMeters),\(coords))\(filter);")
            if end == points.count { break }
            start = end - 1
        } while true

        return "[out:json][timeout:10];(\(clauses.joined()));out geom;"
    }

    private func fetch(query: String) async -> [TunnelWay]? {
        guard let encoded = OSMSpeedLimitService.formURLEncoded(query) else { return nil }
        let body = Data("data=\(encoded)".utf8)

        for endpoint in Tuning.endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(Tuning.userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = body
            // Tight on purpose: a slow mirror means "assume outdoor", never a stall.
            request.timeoutInterval = Tuning.requestTimeout

            do {
                let (data, response) = try await transport(request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    if http.statusCode == 429 || http.statusCode >= 500 { continue }
                    return nil
                }
                return try Self.parseOverpassResponse(data)
            } catch is CancellationError {
                return nil
            } catch {
                if (error as? URLError)?.code == .cancelled || Task.isCancelled { return nil }
                continue
            }
        }
        return nil
    }

    nonisolated static func parseOverpassResponse(_ data: Data) throws -> [TunnelWay] {
        let response = try JSONDecoder().decode(OverpassTunnelResponse.self, from: data)
        return response.elements.compactMap { element in
            guard let geometry = element.geometry, geometry.count >= 2 else { return nil }
            return TunnelWay(wayID: element.id, geometry: geometry)
        }
    }
}

// MARK: - Supporting types

struct TunnelSegment: Equatable {
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D

    static func == (lhs: TunnelSegment, rhs: TunnelSegment) -> Bool {
        lhs.start.latitude == rhs.start.latitude && lhs.start.longitude == rhs.start.longitude
            && lhs.end.latitude == rhs.end.latitude && lhs.end.longitude == rhs.end.longitude
    }
}

private struct OverpassTunnelResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let id: Int
        let geometry: [SpeedLimitPoint]?
    }
}

// MARK: - Tuning

private enum Tuning {
    static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    ]
    static let userAgent = "Steddi/1.0 (steddi.io)"
    static let requestTimeout: TimeInterval = 2
    static let corridorRadiusMeters = 500
    static let downsampleToleranceMeters: Double = 50
    static let maxQueryPoints = 200
    static let maxPointsPerClause = 200
    static let maxCachedRoutes = 4

    /// Within this distance of a tunnel way the driver counts as inside it.
    static let insideRadiusMeters: Double = 30
    /// Portal approach zone where signal loss confirms entry.
    static let portalProximityMeters: Double = 150
    /// Horizontal accuracy beyond this is a degraded fix.
    static let weakAccuracyMeters: Double = 80
    static let weakStreakNearTunnel = 3
    static let weakStreakBlind = 6
    /// Last-good-fix speed below this (m/s) disarms blind detection (~18 mph).
    static let blindMinSpeedMPS: Double = 8
    /// Max duration the BLIND latch (no OSM data) may hold on an unbroken weak-
    /// signal streak with no geometric tunnel signal before it decays. Past
    /// this, a sustained dropout (underground garage, urban canyon, dead-zone)
    /// is treated as "not a tunnel" and the dark theme is released. Sized well
    /// above any plausible blind short tunnel — those restore signal (and break
    /// the streak) in seconds; long mapped tunnels carry OSM geometry and use
    /// the geometric path, which this never touches.
    static let blindLatchMaxSeconds: TimeInterval = 180

    static let entryRampSeconds: TimeInterval = 1
    static let exitFadeSeconds: TimeInterval = 5
}
