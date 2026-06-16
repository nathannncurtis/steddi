import Foundation
import Observation

/// Manages on-disk caching of route data for offline navigation.
/// Active-navigation cache goes to Caches/ (auto-cleaned by OS and by us).
/// User-initiated downloads go to Documents/ (persistent until explicitly deleted).
@Observable
final class OfflineCacheService {
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let downloadsDirectory: URL
    private var cleanupTask: Task<Void, Never>?

    /// Route IDs the user has explicitly downloaded.
    private(set) var downloadedRouteIDs: Set<UUID> = []

    init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        cacheDirectory = caches.appendingPathComponent("SteadyRouteCache", isDirectory: true)

        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        downloadsDirectory = documents.appendingPathComponent("DownloadedRoutes", isDirectory: true)

        ensureDirectoryExists(cacheDirectory)
        ensureDirectoryExists(downloadsDirectory)
        loadDownloadedRouteIDs()
    }

    // MARK: - Active Navigation Cache

    /// Cache route geometry and turn instructions for offline use during navigation.
    func cacheActiveRoute(_ route: Route) throws {
        let data = try encodeCachePayload(for: route)
        let fileURL = cacheDirectory.appendingPathComponent("\(route.id.uuidString).json")
        try data.write(to: fileURL)
    }

    /// Schedule cache cleanup 5 minutes after navigation ends.
    func scheduleCleanup() {
        cleanupTask?.cancel()
        cleanupTask = Task {
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            clearCache()
        }
    }

    /// Cancel any pending cleanup (e.g., if the user starts a new navigation).
    func cancelScheduledCleanup() {
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    /// Delete this service's cached navigation data.
    ///
    /// Removes only the route-cache files this service writes into its own
    /// `cacheDirectory`, rather than `removeItem(at: cacheDirectory)` on the
    /// whole directory. The previous wipe assumed exclusive ownership of the
    /// directory; scoping to our own files means clearing the offline-route
    /// cache can never delete a sibling component's cache that happens to share
    /// the directory, and leaves the directory itself intact.
    func clearCache() {
        let contents = (try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for fileURL in contents where fileURL.pathExtension == "json" {
            try? fileManager.removeItem(at: fileURL)
        }
        ensureDirectoryExists(cacheDirectory)
    }

    // MARK: - User Downloads

    /// Persistently download a route for offline use (user-initiated).
    func downloadRoute(_ route: Route) throws {
        let data = try encodeCachePayload(for: route)
        let fileURL = downloadsDirectory.appendingPathComponent("\(route.id.uuidString).json")
        try data.write(to: fileURL)
        downloadedRouteIDs.insert(route.id)
        saveDownloadedRouteIDs()
    }

    /// Remove a user-downloaded route.
    func deleteDownloadedRoute(_ route: Route) {
        let fileURL = downloadsDirectory.appendingPathComponent("\(route.id.uuidString).json")
        try? fileManager.removeItem(at: fileURL)
        downloadedRouteIDs.remove(route.id)
        saveDownloadedRouteIDs()
    }

    /// Check if a route is available offline (either cached or downloaded).
    func isAvailableOffline(_ route: Route) -> Bool {
        let cached = cacheDirectory.appendingPathComponent("\(route.id.uuidString).json")
        let downloaded = downloadsDirectory.appendingPathComponent("\(route.id.uuidString).json")
        return fileManager.fileExists(atPath: cached.path) || fileManager.fileExists(atPath: downloaded.path)
    }

    /// Load cached/downloaded route data for offline navigation.
    func loadCachedRoute(_ route: Route) throws -> CachedRouteData? {
        let downloaded = downloadsDirectory.appendingPathComponent("\(route.id.uuidString).json")
        let cached = cacheDirectory.appendingPathComponent("\(route.id.uuidString).json")

        // Prefer user download over auto-cache
        let fileURL = fileManager.fileExists(atPath: downloaded.path) ? downloaded : cached

        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(CachedRouteData.self, from: data)
    }

    // MARK: - Private

    private func encodeCachePayload(for route: Route) throws -> Data {
        let payload = CachedRouteData(
            routeID: route.id,
            encodedPolyline: route.encodedPolyline,
            distanceMeters: route.distanceMeters,
            typicalDurationSeconds: route.typicalDurationSeconds,
            cachedAt: Date()
        )
        return try JSONEncoder().encode(payload)
    }

    private func ensureDirectoryExists(_ url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Persist the set of downloaded route IDs so it survives app restarts.
    private func saveDownloadedRouteIDs() {
        let ids = downloadedRouteIDs.map(\.uuidString)
        let fileURL = downloadsDirectory.appendingPathComponent(".manifest.json")
        if let data = try? JSONEncoder().encode(ids) {
            try? data.write(to: fileURL)
        }
    }

    private func loadDownloadedRouteIDs() {
        let fileURL = downloadsDirectory.appendingPathComponent(".manifest.json")
        guard let data = try? Data(contentsOf: fileURL),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return }
        downloadedRouteIDs = Set(ids.compactMap(UUID.init))
    }
}

/// Serializable representation of cached route data.
struct CachedRouteData: Codable {
    let routeID: UUID
    let encodedPolyline: String
    let distanceMeters: Double?
    let typicalDurationSeconds: Double?
    let cachedAt: Date
}
