import Foundation
import SwiftData
import os

private let storeLog = Logger(subsystem: "to.nathancurtis.steddi", category: "ModelStore")

/// Locates the SwiftData store, preferring the App Group container so app
/// extensions and intents (Siri, widgets) can read the same data as the app.
///
/// An existing legacy store (the default Application Support location) is
/// migrated into the group container by copying its files — the legacy store
/// is never deleted, so a failed migration can always fall back to it.
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
            Report.self
        ])
    }

    // MARK: - Store URLs

    /// Store URL inside the App Group container, if the container is available.
    static func groupStoreURL(fileManager: FileManager = .default) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(storeFilename)
    }

    /// The legacy default SwiftData store location (Application Support).
    static func legacyStoreURL() -> URL {
        URL.applicationSupportDirectory.appendingPathComponent(legacyStoreFilename)
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
    /// unavailable or the copy fails. Never deletes the legacy store.
    static func selectStoreURL(
        groupURL: URL?,
        legacyURL: URL,
        fileManager: FileManager = .default
    ) -> Selection {
        guard let groupURL else {
            storeLog.warning("App group container unavailable — using legacy store location")
            return .legacy(legacyURL)
        }

        let groupExists = fileManager.fileExists(atPath: groupURL.path)
        let legacyExists = fileManager.fileExists(atPath: legacyURL.path)

        if !groupExists && legacyExists {
            do {
                try copyStoreFiles(from: legacyURL, to: groupURL, fileManager: fileManager)
                storeLog.info("Migrated store from \(legacyURL.path) to \(groupURL.path)")
            } catch {
                storeLog.error("Store migration copy failed (\(error.localizedDescription)) — staying on legacy store")
                return .legacy(legacyURL)
            }
        }
        return .group(groupURL)
    }

    /// Copy a SQLite store and its -shm/-wal sidecar files.
    static func copyStoreFiles(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for suffix in ["", "-shm", "-wal"] {
            let src = URL(fileURLWithPath: source.path + suffix)
            let dst = URL(fileURLWithPath: destination.path + suffix)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            if fileManager.fileExists(atPath: dst.path) {
                try fileManager.removeItem(at: dst)
            }
            try fileManager.copyItem(at: src, to: dst)
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
        let selection = selectStoreURL(groupURL: groupStoreURL(), legacyURL: legacyStoreURL())

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

        let legacyURL = legacyStoreURL()
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

    /// Open a read-only container on the group store for intents and
    /// extensions. Throws if the group store doesn't exist yet.
    static func makeReadOnlyGroupContainer(fileManager: FileManager = .default) throws -> ModelContainer {
        guard let url = groupStoreURL(fileManager: fileManager),
              fileManager.fileExists(atPath: url.path) else {
            throw StoreError.groupStoreUnavailable
        }
        let config = ModelConfiguration(url: url, allowsSave: false)
        return try ModelContainer(for: schema, configurations: [config])
    }

    enum StoreError: Error {
        case groupStoreUnavailable
    }
}
