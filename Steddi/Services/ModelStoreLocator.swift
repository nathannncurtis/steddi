import Foundation
import SwiftData
import os

private let storeLog = Logger(subsystem: "to.nathancurtis.steddi", category: "ModelStore")

/// Locates the SwiftData store, preferring a fixed path in the App Group
/// container so app extensions and intents (Siri, widgets) can read the same
/// data as the app.
///
/// An existing legacy store (wherever SwiftData's default ModelContainer put
/// it — see `legacyStoreCandidates`) is migrated to the fixed path by copying
/// its files — the legacy store is never deleted, so a failed migration can
/// always fall back to it.
enum ModelStoreLocator {

    static let appGroupIdentifier = "group.to.nathancurtis.steddi"
    static let storeFilename = "Steddi.store"
    static let legacyStoreFilename = "default.store"

    /// Full schema for the app's model graph.
    static var schema: Schema {
        Schema([
            PinnedLocation.self,
            Commute.self,
            Route.self,
            DriveRecord.self,
            NoGoZone.self,
            CommuteTrip.self,
            Report.self,
            CommuteAnalyticsAggregate.self,
            Trip.self,
            TripStop.self
        ])
    }

    // MARK: - Store URLs

    /// Store URL inside the App Group container, if the container is available.
    static func groupStoreURL(fileManager: FileManager = .default) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(storeFilename)
    }

    /// Locations SwiftData's default `ModelContainer(for:)` may have used for
    /// existing installs, in priority order:
    ///
    /// 1. `<group container>/Library/Application Support/default.store` — when
    ///    the app carries exactly one app-group entitlement (Steddi has shipped
    ///    with `group.to.nathancurtis.steddi` since before the store move),
    ///    SwiftData's default container already lives inside the group
    ///    container, *not* the app sandbox. Verified empirically: a production
    ///    build creates its store here.
    /// 2. `<sandbox>/Library/Application Support/default.store` — the default
    ///    for apps without an app-group entitlement, kept as a safety net for
    ///    any install that predates the entitlement.
    static func legacyStoreCandidates(fileManager: FileManager = .default) -> [URL] {
        var candidates: [URL] = []
        if let group = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            candidates.append(
                group
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
                    .appendingPathComponent(legacyStoreFilename)
            )
        }
        candidates.append(URL.applicationSupportDirectory.appendingPathComponent(legacyStoreFilename))
        return candidates
    }

    /// The first legacy candidate that actually exists on disk, if any.
    static func existingLegacyStoreURL(
        candidates: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    // MARK: - Selection

    enum Selection: Equatable {
        case group(URL)
        case legacy(URL)

        var url: URL {
            switch self {
            case .group(let url): return url
            case .legacy(let url): return url
            }
        }
    }

    /// Pick which store file to open. If a legacy store exists and the group
    /// container has none, copy the store files into the group container
    /// first. Falls back to the legacy location if the group container is
    /// unavailable or the copy fails. Idempotent — safe to run on every
    /// launch. Never deletes the legacy store.
    static func selectStoreURL(
        groupURL: URL?,
        legacyCandidates: [URL],
        fileManager: FileManager = .default
    ) -> Selection {
        let existingLegacy = existingLegacyStoreURL(
            candidates: legacyCandidates,
            fileManager: fileManager
        )
        // Where to land when the group store can't be used: an existing
        // legacy store, or the sandbox default location on a fresh install.
        let legacyFallback = existingLegacy
            ?? legacyCandidates.last
            ?? URL.applicationSupportDirectory.appendingPathComponent(legacyStoreFilename)

        guard let groupURL else {
            storeLog.warning("App group container unavailable — using legacy store location")
            return .legacy(legacyFallback)
        }

        let groupExists = fileManager.fileExists(atPath: groupURL.path)

        if !groupExists, let legacy = existingLegacy {
            do {
                try copyStoreFiles(from: legacy, to: groupURL, fileManager: fileManager)
                storeLog.info("Migrated store from \(legacy.path) to \(groupURL.path)")
            } catch {
                storeLog.error("Store migration copy failed (\(error.localizedDescription)) — staying on legacy store")
                return .legacy(legacy)
            }
        }
        return .group(groupURL)
    }

    /// Copy a SQLite store and its -shm/-wal sidecar files.
    ///
    /// Files are staged in a temporary directory next to the destination
    /// (same volume) and then moved into place with rename(2). The main store
    /// file is renamed last: `selectStoreURL` gates migration on its
    /// existence, so a crash mid-copy can never leave a half-migrated store
    /// that a later launch would mistake for a finished one.
    static func copyStoreFiles(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let destinationDir = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let staging = destinationDir.appendingPathComponent(
            ".store-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        // Sidecars first, the main store file last.
        let suffixes = ["-shm", "-wal", ""]

        for suffix in suffixes {
            let src = URL(fileURLWithPath: source.path + suffix)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            let staged = staging.appendingPathComponent(destination.lastPathComponent + suffix)
            try fileManager.copyItem(at: src, to: staged)
        }

        for suffix in suffixes {
            let staged = staging.appendingPathComponent(destination.lastPathComponent + suffix)
            guard fileManager.fileExists(atPath: staged.path) else { continue }
            let dst = URL(fileURLWithPath: destination.path + suffix)
            if fileManager.fileExists(atPath: dst.path) {
                try fileManager.removeItem(at: dst)
            }
            // Same-volume move is an atomic rename.
            try fileManager.moveItem(at: staged, to: dst)
        }
    }

    // MARK: - Containers

    struct ContainerResult {
        let container: ModelContainer
        /// Non-nil when running on an in-memory store — data won't persist.
        let warning: String?
    }

    /// Build the app's main container with a fallback chain:
    /// group store → legacy store → in-memory (with a user-visible warning).
    static func makeAppContainer() -> ContainerResult {
        let candidates = legacyStoreCandidates()
        let selection = selectStoreURL(groupURL: groupStoreURL(), legacyCandidates: candidates)

        if case .group(let url) = selection {
            do {
                let container = try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(url: url)]
                )
                storeLog.info("Opened SwiftData store in app group container: \(url.path)")
                return ContainerResult(container: container, warning: nil)
            } catch {
                storeLog.error("Failed to open group store at \(url.path) (\(error.localizedDescription)) — falling back to legacy store")
            }
        }

        let legacyURL: URL
        if case .legacy(let url) = selection {
            legacyURL = url
        } else {
            legacyURL = existingLegacyStoreURL(candidates: candidates)
                ?? candidates.last
                ?? URL.applicationSupportDirectory.appendingPathComponent(legacyStoreFilename)
        }
        do {
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(url: legacyURL)]
            )
            storeLog.info("Opened SwiftData store at legacy location: \(legacyURL.path)")
            return ContainerResult(container: container, warning: nil)
        } catch {
            storeLog.fault("Failed to open legacy store (\(error.localizedDescription)) — using in-memory store")
        }

        do {
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            return ContainerResult(
                container: container,
                warning: "Steddi couldn't open its saved data. Changes made now won't be saved."
            )
        } catch {
            // Creating an in-memory container from the schema alone should
            // never fail; if it does there is nothing left to run with.
            fatalError("Unable to create any ModelContainer: \(error)")
        }
    }

    /// Store to read for intents and extensions: the group store when it
    /// exists, otherwise an existing legacy store — the user may not have
    /// launched the app (which performs the migration) since updating.
    static func readOnlyStoreURL(
        groupURL: URL?,
        legacyCandidates: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        if let groupURL, fileManager.fileExists(atPath: groupURL.path) {
            return groupURL
        }
        return existingLegacyStoreURL(candidates: legacyCandidates, fileManager: fileManager)
    }

    /// Open a read-only container on the shared store for intents and
    /// extensions, falling back to the legacy store until the app has run
    /// its migration. Throws if no store exists on disk at all.
    static func makeReadOnlySharedContainer(fileManager: FileManager = .default) throws -> ModelContainer {
        guard let url = readOnlyStoreURL(
            groupURL: groupStoreURL(fileManager: fileManager),
            legacyCandidates: legacyStoreCandidates(fileManager: fileManager),
            fileManager: fileManager
        ) else {
            throw StoreError.sharedStoreUnavailable
        }
        let config = ModelConfiguration(url: url, allowsSave: false)
        return try ModelContainer(for: schema, configurations: [config])
    }

    enum StoreError: Error {
        case sharedStoreUnavailable
    }
}
