import Foundation
import SwiftData
import CoreLocation
import CryptoKit
import Observation
import os

private let speedCameraLog = Logger(subsystem: "to.nathancurtis.steddi", category: "SpeedCamera")

// MARK: - OSM value type

/// An enforcement camera sourced from OpenStreetMap via Overpass. A value type
/// (not a SwiftData model): OSM cameras are fetched per-route and held in the
/// spatial index for the drive, never persisted. Crowdsourced sightings use the
/// persisted `CameraReport` model instead; `SpeedCameraService` unifies both.
struct SpeedCameraNode: Codable, Equatable {
    let nodeID: Int
    /// Camera kind inferred from OSM tags (highway=speed_camera,
    /// enforcement=maxspeed/traffic_signals, etc.).
    let kind: CameraReportKind
    let lat: Double
    let lon: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// On-disk cache payload for one corridor's OSM camera data.
struct CachedSpeedCameras: Codable {
    let cameras: [SpeedCameraNode]
    let fetchedAt: Date
}

// MARK: - Proximity match

/// A unified proximity hit, abstracting over OSM-sourced cameras and
/// user-reported ones so the engine and overlay don't care about the origin.
/// Carries a stable `alertID` for per-session debounce and the data the alert
/// UI/voice needs.
struct SpeedCameraAlert: Equatable {
    /// Stable identity for debounce: OSM node id or the report's UUID string.
    let alertID: String
    let kind: CameraReportKind
    let coordinate: CLLocationCoordinate2D
    /// Distance from the probe point at match time, meters.
    let distanceMeters: CLLocationDistance

    static func == (lhs: SpeedCameraAlert, rhs: SpeedCameraAlert) -> Bool {
        lhs.alertID == rhs.alertID
            && lhs.kind == rhs.kind
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.distanceMeters == rhs.distanceMeters
    }
}

// MARK: - Service

/// Speed-camera and red-light-camera service.
///
/// Two data sources, one spatial index:
/// 1. OSM cameras fetched per-route from Overpass (`highway=speed_camera` and
///    `enforcement` nodes), corridor-prefetched and disk-cached for 30 days —
///    reusing `OSMSpeedLimitService`'s downsample/cache-key plumbing.
/// 2. Crowdsourced `CameraReport` rows the user submits, stored locally (shaped
///    for a future sync — no backend).
///
/// Proximity alerts come from a ~250m spatial grid (same shape as
/// `RoadConditionService` / `OSMSpeedLimitService`): O(1) cell lookup plus a
/// scan of the matched cell and its 8 neighbors. The index is rebuilt when the
/// OSM set loads or any report mutates so it never serves stale data.
///
/// Follows the codebase's singleton `@Observable @MainActor` service pattern.
@Observable
@MainActor
final class SpeedCameraService {
    static let shared = SpeedCameraService()

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    // MARK: - Dependencies

    private let transport: Transport
    private let cacheDirectory: URL
    private let now: () -> Date

    /// Shared SwiftData store, nil until `configure(container:)`. CRUD is a no-op
    /// while unconfigured so previews and early callers don't crash.
    private var modelContainer: ModelContainer?
    private var sharedContext: ModelContext?

    // MARK: - OSM corridor state

    /// Route key of the currently indexed OSM camera set.
    private(set) var loadedRouteKey: String?
    private(set) var isPrefetching = false
    /// OSM cameras loaded for the current corridor.
    private var osmCameras: [SpeedCameraNode] = []

    /// Monotonic prefetch token: a reroute can start a new prefetch while an
    /// older one is in flight; only the newest generation may publish.
    private var prefetchGeneration = 0

    // MARK: - Index

    /// Unified spatial grid over OSM cameras + active user reports. Rebuilt on
    /// OSM load or any report mutation.
    private var index: SpeedCameraGridIndex?

    init(
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        cacheDirectory: URL? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.transport = transport
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.cacheDirectory = caches.appendingPathComponent("SpeedCameras", isDirectory: true)
        }
        self.now = now
    }

    /// Wire up the shared container at launch. Idempotent.
    func configure(container: ModelContainer) {
        self.modelContainer = container
        self.sharedContext = ModelContext(container)
    }

    private var context: ModelContext? { sharedContext }

    /// Exposed for tests so they can insert reports into the same context the
    /// service reads, keeping queries consistent.
    var testContext: ModelContext? { sharedContext }

    // MARK: - OSM Prefetch

    /// Fetch enforcement cameras within `SpeedCameraTuning.aroundRadiusMeters`
    /// of the route polyline. Disk-cache hit short-circuits the network.
    ///
    /// Disk IO, JSON coding, polyline simplification, and the index build all run
    /// off the main actor so a long-corridor payload doesn't hitch the UI at
    /// route start.
    func prefetchOSMCameras(for polyline: [CLLocationCoordinate2D], routeKey: String) async {
        guard polyline.count >= 2 else { return }
        prefetchGeneration += 1
        let generation = prefetchGeneration
        isPrefetching = true
        defer {
            if generation == prefetchGeneration { isPrefetching = false }
        }

        let directory = cacheDirectory
        let currentDate = now()
        let (fileURL, cached) = await Task.detached(priority: .userInitiated) { () -> (URL, CachedSpeedCameras?) in
            let fileURL = directory.appendingPathComponent("\(Self.cacheKey(for: polyline)).json")
            return (fileURL, Self.loadCachedPayload(at: fileURL, now: currentDate))
        }.value
        if let cached {
            install(cameras: cached.cameras, routeKey: routeKey, generation: generation)
            return
        }

        // Reuse OSMSpeedLimitService's downsample (RDP + hard cap) so the camera
        // corridor query matches the speed-limit corridor sampling exactly.
        let query = await Task.detached(priority: .userInitiated) {
            let sampled = OSMSpeedLimitService.downsample(
                polyline,
                tolerance: SpeedCameraTuning.downsampleToleranceMeters,
                maxPoints: SpeedCameraTuning.maxQueryPoints
            )
            return Self.overpassQuery(for: sampled)
        }.value
        guard let fetched = await fetch(query: query) else { return }

        let payload = CachedSpeedCameras(cameras: fetched, fetchedAt: now())
        await Task.detached(priority: .utility) {
            Self.savePayload(payload, to: fileURL)
        }.value
        install(cameras: fetched, routeKey: routeKey, generation: generation)
    }

    /// Replace the OSM camera set and rebuild the unified index — unless a newer
    /// prefetch generation started in the meantime.
    private func install(cameras: [SpeedCameraNode], routeKey: String, generation: Int) {
        guard generation == prefetchGeneration else { return }
        osmCameras = cameras
        loadedRouteKey = routeKey
        rebuildIndex()
    }

    /// Directly load an OSM camera set (no network). For tests and previews.
    func loadOSMCameras(_ cameras: [SpeedCameraNode], routeKey: String) {
        prefetchGeneration += 1
        osmCameras = cameras
        loadedRouteKey = routeKey
        rebuildIndex()
    }

    // MARK: - CRUD (crowdsourced reports)

    /// Persist a new active user camera report. Returns the inserted model (nil
    /// if the store is unavailable). Rebuilds the spatial index.
    @discardableResult
    func reportCamera(
        kind: CameraReportKind,
        coordinate: CLLocationCoordinate2D,
        note: String? = nil
    ) -> CameraReport? {
        guard let context else { return nil }
        let report = CameraReport(
            kind: kind,
            coordinate: coordinate,
            source: .userReport,
            note: note,
            createdAt: now()
        )
        context.insert(report)
        save(context)
        rebuildIndex()
        return report
    }

    /// User confirmed "still there?" — reset the decay timer and bump the
    /// confirmation counter (a future sync uses this to merge sightings).
    func confirmReport(_ report: CameraReport) {
        report.lastConfirmedAt = now()
        report.confirmationCount += 1
        report.status = .active
        persistMutation(of: report)
    }

    /// User reported the camera gone — soft-delete to `.expired`. Leaves the map
    /// and alerts immediately but survives until the sweep.
    func dismissReport(_ report: CameraReport) {
        report.status = .expired
        persistMutation(of: report)
    }

    /// All active user reports, newest first.
    func fetchActiveReports() -> [CameraReport] {
        guard let context else { return [] }
        let descriptor = FetchDescriptor<CameraReport>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.status == .active }
    }

    /// Hard-delete reports past their kind-specific expiry window (6h for mobile
    /// traps, 365d for fixed cameras), plus any soft-expired report past it. Run
    /// at app launch. Returns the number deleted.
    @discardableResult
    func sweepExpiredReports() -> Int {
        guard let context else { return 0 }
        let reference = now()
        let descriptor = FetchDescriptor<CameraReport>()
        guard let all = try? context.fetch(descriptor), !all.isEmpty else { return 0 }
        let stale = all.filter { report in
            let age = reference.timeIntervalSince(report.lastConfirmedAt)
            return age > CameraReportDecay.expirySeconds(for: report.kind)
        }
        guard !stale.isEmpty else { return 0 }
        for report in stale { context.delete(report) }
        save(context)
        rebuildIndex()
        speedCameraLog.info("Swept \(stale.count) expired camera reports")
        return stale.count
    }

    // MARK: - Proximity

    /// Closest qualifying camera within `proximityThresholdMeters` of the current
    /// position, for firing nav-time alerts. Returns nil when nothing's in range.
    /// Uses the unified grid index. Heading-gated: a camera more than
    /// `SpeedCameraTuning.headingConeDegrees` off the travel bearing is skipped
    /// so the user isn't warned about a camera on the opposing carriageway.
    func checkProximity(
        currentCoord: CLLocationCoordinate2D,
        heading: Double?,
        proximityThresholdMeters: CLLocationDistance = SpeedCameraTuning.alertRadiusMeters
    ) -> SpeedCameraAlert? {
        guard let index else { return nil }
        let candidates = index.candidates(near: currentCoord)
        return Self.closestAlert(
            currentCoord: currentCoord,
            heading: heading,
            candidates: candidates,
            proximityThresholdMeters: proximityThresholdMeters
        )
    }

    /// Pure proximity selection over an explicit candidate list, so navigation
    /// code and tests can call it without an indexed route.
    ///
    /// Within range, the highest-priority kind wins (red-light beats speed beats
    /// mobile); ties break to the closest. A camera behind the driver (more than
    /// `headingConeDegrees` from the travel bearing toward it) is ignored when a
    /// heading is known — approaching cameras only.
    nonisolated static func closestAlert(
        currentCoord: CLLocationCoordinate2D,
        heading: Double?,
        candidates: [SpeedCameraAlert],
        proximityThresholdMeters: CLLocationDistance
    ) -> SpeedCameraAlert? {
        candidates
            .compactMap { candidate -> SpeedCameraAlert? in
                let distance = RouteGeometry.haversineDistance(from: currentCoord, to: candidate.coordinate)
                guard distance < proximityThresholdMeters else { return nil }
                if let heading, !isAhead(from: currentCoord, to: candidate.coordinate, heading: heading) {
                    return nil
                }
                return SpeedCameraAlert(
                    alertID: candidate.alertID,
                    kind: candidate.kind,
                    coordinate: candidate.coordinate,
                    distanceMeters: distance
                )
            }
            .min { lhs, rhs in
                if lhs.kind.priority != rhs.kind.priority {
                    return lhs.kind.priority > rhs.kind.priority
                }
                return lhs.distanceMeters < rhs.distanceMeters
            }
    }

    /// Whether a target lies ahead of travel: the bearing to the target is within
    /// `headingConeDegrees` of the heading. Very close targets (inside
    /// `aheadBypassMeters`) always count — at point-blank range bearing is noisy
    /// and the camera is effectively at the driver.
    nonisolated static func isAhead(
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D,
        heading: Double
    ) -> Bool {
        let distance = RouteGeometry.haversineDistance(from: origin, to: target)
        if distance <= SpeedCameraTuning.aheadBypassMeters { return true }
        let bearingToTarget = CustomRouteBuilder.bearing(from: origin, to: target)
        var diff = abs(bearingToTarget - heading).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        return diff <= SpeedCameraTuning.headingConeDegrees
    }

    // MARK: - Index management

    /// Rebuild the unified index from current OSM cameras + active reports.
    private func rebuildIndex() {
        let reports = fetchActiveReports()
        index = SpeedCameraGridIndex(osmCameras: osmCameras, reports: reports)
    }

    private func persistMutation(of report: CameraReport) {
        if let ctx = report.modelContext {
            save(ctx)
        } else {
            save(context)
        }
        rebuildIndex()
    }

    private func save(_ context: ModelContext?) {
        guard let context else { return }
        do {
            try context.save()
        } catch {
            speedCameraLog.error("Failed to save camera report change: \(error.localizedDescription)")
        }
    }

    // MARK: - Network

    private func fetch(query: String) async -> [SpeedCameraNode]? {
        guard let encoded = OSMSpeedLimitService.formURLEncoded(query) else { return nil }
        let body = Data("data=\(encoded)".utf8)

        for endpoint in SpeedCameraTuning.endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(SpeedCameraTuning.userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = body
            request.timeoutInterval = 30

            do {
                let (data, response) = try await transport(request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    if http.statusCode == 429 || http.statusCode >= 500 { continue }
                    return nil
                }
                return try await Task.detached(priority: .userInitiated) {
                    try Self.parseOverpassResponse(data)
                }.value
            } catch is CancellationError {
                return nil
            } catch {
                if (error as? URLError)?.code == .cancelled || Task.isCancelled { return nil }
                continue
            }
        }
        return nil
    }

    /// Build the Overpass QL query for enforcement-camera nodes along a
    /// downsampled polyline. Targets `highway=speed_camera` plus `enforcement`
    /// nodes (maxspeed / maxspeed_average / traffic_signals). Splits into
    /// multiple `around` clauses within one request when the point count exceeds
    /// the per-clause cap.
    nonisolated static func overpassQuery(for points: [CLLocationCoordinate2D]) -> String {
        guard !points.isEmpty else { return "" }

        var clauses: [String] = []
        var start = 0
        repeat {
            let end = min(start + SpeedCameraTuning.maxPointsPerClause, points.count)
            let coords = points[start..<end]
                .map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }
                .joined(separator: ",")
            let r = SpeedCameraTuning.aroundRadiusMeters
            clauses.append(#"node(around:\#(r),\#(coords))["highway"="speed_camera"];"#)
            clauses.append(#"node(around:\#(r),\#(coords))["enforcement"];"#)
            if end == points.count { break }
            start = end - 1 // overlap one point so coverage is continuous
        } while true

        return "[out:json][timeout:25];(\(clauses.joined()));out tags;"
    }

    // MARK: - Parsing

    /// Convert an Overpass JSON response into camera nodes. Maps OSM tags to a
    /// `CameraReportKind`; nodes that look like cameras but carry no recognizable
    /// kind default to a plain speed camera.
    nonisolated static func parseOverpassResponse(_ data: Data) throws -> [SpeedCameraNode] {
        let response = try JSONDecoder().decode(OverpassCameraResponse.self, from: data)
        return response.elements.compactMap { element in
            guard element.type == "node",
                  let lat = element.lat,
                  let lon = element.lon else { return nil }
            guard let kind = cameraKind(from: element.tags) else { return nil }
            return SpeedCameraNode(nodeID: element.id, kind: kind, lat: lat, lon: lon)
        }
    }

    /// Classify an OSM node's tags into a camera kind, or nil if the node isn't
    /// an enforcement camera at all.
    ///
    /// Red-light precedence: a node enforcing traffic signals (with or without a
    /// speed component) is a red-light camera. `enforcement=maxspeed` /
    /// `average_speed`, or `highway=speed_camera`, is a speed camera.
    nonisolated static func cameraKind(from tags: [String: String]?) -> CameraReportKind? {
        guard let tags else { return nil }
        let enforcement = tags["enforcement"]?.lowercased()
        let highway = tags["highway"]?.lowercased()

        if let enforcement {
            if enforcement.contains("traffic_signals") || enforcement.contains("red") {
                return .redLightCamera
            }
            if enforcement.contains("maxspeed") || enforcement.contains("average_speed")
                || enforcement.contains("speed") {
                return .speedCamera
            }
            // An enforcement node of some other kind (toll, check, etc.) — not a
            // camera we alert on.
            return nil
        }

        if highway == "speed_camera" {
            return .speedCamera
        }
        return nil
    }

    // MARK: - Disk Cache

    /// Cache key: SHA256 of the precision-6 encoded polyline. Reuses the same
    /// scheme as `OSMSpeedLimitService` (distinct cache directory keeps the
    /// payloads separate).
    nonisolated static func cacheKey(for polyline: [CLLocationCoordinate2D]) -> String {
        let encoded = PolylineEncoder.encode(polyline, precision: 6)
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func loadCachedPayload(at fileURL: URL, now: Date) -> CachedSpeedCameras? {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(CachedSpeedCameras.self, from: data) else { return nil }
        guard now.timeIntervalSince(payload.fetchedAt) < SpeedCameraTuning.cacheTTL else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return payload
    }

    private nonisolated static func savePayload(_ payload: CachedSpeedCameras, to fileURL: URL) {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL)
    }
}

// MARK: - Grid Index

/// A ~250m spatial hash grid over a set of cameras (OSM + user reports). Each
/// camera is registered in the single cell containing its point; a query gathers
/// the center cell plus its 8 neighbors so a camera near a cell boundary is still
/// found within the alert radius. Immutable once built — the service throws it
/// away and rebuilds on mutation/load.
///
/// Same shape as `RoadConditionGridIndex`, but unifies two source types into one
/// list of `SpeedCameraAlert` so the proximity check is source-agnostic.
struct SpeedCameraGridIndex {
    /// Degrees per cell. The center-plus-8-neighbors search only guarantees a
    /// hit out to ONE cell width (worst case: the query sits at its cell edge),
    /// and that width is smallest in longitude at high latitudes. To never miss
    /// a camera inside the ~350m alert radius, the cell must exceed 350m on its
    /// smallest axis across US latitudes: 0.005° ≈ 556m N/S, and ≈365m E/W even
    /// at ~49°N (cos·111.32km·0.005). The old 0.0025° (~230m E/W in SoCal) could
    /// drop a camera 230–350m away that sat near a cell boundary.
    static let cellSizeDegrees = 0.005

    private let cameras: [SpeedCameraAlert]
    private let grid: [GridKey: [Int]]

    init(osmCameras: [SpeedCameraNode], reports: [CameraReport]) {
        var cameras: [SpeedCameraAlert] = []
        cameras.reserveCapacity(osmCameras.count + reports.count)
        for node in osmCameras {
            cameras.append(SpeedCameraAlert(
                alertID: "osm-\(node.nodeID)",
                kind: node.kind,
                coordinate: node.coordinate,
                distanceMeters: 0
            ))
        }
        for report in reports where report.status == .active {
            cameras.append(SpeedCameraAlert(
                alertID: "report-\(report.id.uuidString)",
                kind: report.kind,
                coordinate: report.coordinate,
                distanceMeters: 0
            ))
        }
        self.cameras = cameras

        var grid: [GridKey: [Int]] = [:]
        for (i, camera) in cameras.enumerated() {
            grid[Self.key(for: camera.coordinate), default: []].append(i)
        }
        self.grid = grid
    }

    /// Cameras in the cell containing `coordinate` and its 8 neighbors.
    func candidates(near coordinate: CLLocationCoordinate2D) -> [SpeedCameraAlert] {
        let centerLat = Self.cellIndex(coordinate.latitude)
        let centerLon = Self.cellIndex(coordinate.longitude)
        var result: [SpeedCameraAlert] = []
        for dLat in -1...1 {
            for dLon in -1...1 {
                if let indices = grid[GridKey(lat: centerLat + dLat, lon: centerLon + dLon)] {
                    for i in indices { result.append(cameras[i]) }
                }
            }
        }
        return result
    }

    /// Number of occupied cells — exposed for tests asserting index shape.
    var occupiedCellCount: Int { grid.count }
    /// Total cameras indexed.
    var cameraCount: Int { cameras.count }

    static func cellIndex(_ degrees: Double) -> Int {
        Int(floor(degrees / cellSizeDegrees))
    }

    private static func key(for coordinate: CLLocationCoordinate2D) -> GridKey {
        GridKey(lat: cellIndex(coordinate.latitude), lon: cellIndex(coordinate.longitude))
    }

    struct GridKey: Hashable {
        let lat: Int
        let lon: Int
    }
}

// MARK: - Overpass Response

private struct OverpassCameraResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let type: String
        let id: Int
        let lat: Double?
        let lon: Double?
        let tags: [String: String]?
    }
}

// MARK: - Tuning

enum SpeedCameraTuning {
    /// Overpass mirrors, tried in order until one succeeds.
    static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    ]
    static let userAgent = "Steddi/1.0 (steddi.io)"
    static let downsampleToleranceMeters: Double = 25
    static let maxQueryPoints = 250
    static let maxPointsPerClause = 250
    /// Cameras within this distance of the corridor are fetched. Wider than the
    /// speed-limit corridor (25m) because a camera mounted on a gantry or pole
    /// can sit further from the carriageway centerline.
    static let aroundRadiusMeters = 50
    static let cacheTTL: TimeInterval = 30 * 24 * 3600
    /// Alert when within this distance of a camera ahead — far enough to react
    /// and ease off, close enough not to fire blocks early.
    static let alertRadiusMeters: CLLocationDistance = 350
    /// Heading cone (half-angle): a camera whose bearing from the driver is
    /// within this of the travel heading counts as "ahead".
    static let headingConeDegrees: Double = 75
    /// Below this distance, skip the ahead/behind heading test — bearing is too
    /// noisy at point-blank range.
    static let aheadBypassMeters: CLLocationDistance = 40
}
