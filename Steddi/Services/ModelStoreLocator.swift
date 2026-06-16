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

    /// Set once the group store has opened successfully (post-migration). After
    /// this, the group store is the single source of truth: a later group-open
    /// failure must NOT silently divert to the never-deleted, pre-migration
    /// legacy store (which would strand the user on stale data and split writes
    /// across two stores). See `makeAppContainer`.
    static let groupStoreEstablishedKey = "steddi.groupStoreEstablished"

    /// Full schema for the app's model graph — the single source of truth every
    /// container opens, so the app store, the read-only shared store, and the
    /// in-memory fallback can never drift apart. See `SteddiSchema`.
    ///
    /// There is no explicit `SchemaMigrationPlan`: every shipped schema change has
    /// been purely additive and is handled by SwiftData's automatic lightweight
    /// migration when the container opens. `SteddiSchema` documents why, and when a
    /// real versioned plan would be warranted.
    static var schema: Schema { SteddiSchema.current }

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

    /// Build the app's main container.
    ///
    /// Recovery strategy (chosen to avoid split-brain / silent data loss):
    /// - Normal path: open the group store. On first success record the
    ///   `groupStoreEstablished` marker — from then on the group store is the
    ///   single source of truth.
    /// - If the group open fails, retry it once: the most plausible failures
    ///   (transient App Group container unavailability at boot, a file still
    ///   protected while the device is locked) are momentary and self-heal.
    /// - If the group open STILL fails once the group store is *established*
    ///   (the marker is set — the app has previously opened and written it), do
    ///   NOT silently reopen the never-deleted, pre-migration legacy store
    ///   read-write. That would strand the user on stale data and split new
    ///   writes across two stores. Surface the in-memory warning instead so the
    ///   user sees "changes won't be saved" rather than quietly losing their
    ///   recent drives/commutes.
    /// - If the group open fails and the store was NEVER established, the group
    ///   file is at most a just-landed migration copy that no app write has ever
    ///   touched — there is no divergent group data to lose, but the copy itself
    ///   is suspect (corruption, interrupted prior copy, schema-incompatible).
    ///   Quarantine that suspect copy so the next launch re-attempts migration,
    ///   then open the never-deleted legacy store READ-WRITE so the user keeps
    ///   their intact data rather than being stranded on a dead, unopenable
    ///   store. (Merely checking `fileExists` here would wrongly treat the failed
    ///   copy as established and divert to in-memory forever.)
    /// - Legacy is opened read-write when the group store was never established
    ///   (the migration copy failed and `selectStoreURL` returned `.legacy`, or
    ///   the copied group store could not be opened and was quarantined above) —
    ///   there is no divergent group data to lose then.
    /// - Last resort is the in-memory store with a user-visible warning.
    static func makeAppContainer(defaults: UserDefaults = .standard) -> ContainerResult {
        makeAppContainer(
            groupURL: groupStoreURL(),
            legacyCandidates: legacyStoreCandidates(),
            defaults: defaults
        )
    }

    /// Injectable core of `makeAppContainer`, exposed for tests so the recovery
    /// path (a copied-but-unopenable group store with an intact legacy store) can
    /// be exercised against real on-disk containers without the real App Group
    /// container. Production calls the parameterless overload above.
    static func makeAppContainer(
        groupURL: URL?,
        legacyCandidates: [URL],
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> ContainerResult {
        let selection = selectStoreURL(
            groupURL: groupURL,
            legacyCandidates: legacyCandidates,
            fileManager: fileManager
        )

        if case .group(let url) = selection {
            // One retry to ride out a transient container-unavailability at boot.
            for attempt in 1...2 {
                do {
                    let container = try ModelContainer(
                        for: schema,
                        configurations: [ModelConfiguration(url: url)]
                    )
                    defaults.set(true, forKey: groupStoreEstablishedKey)
                    storeLog.info("Opened SwiftData store in app group container: \(url.path)")
                    return ContainerResult(container: container, warning: nil)
                } catch {
                    storeLog.error("Failed to open group store at \(url.path) (attempt \(attempt)/2): \(error.localizedDescription)")
                }
            }

            // Group open failed after retry. If the group store is ESTABLISHED
            // (the app has opened and written it before), it is the source of
            // truth: refuse to diverge onto the stale legacy store — warn instead.
            let groupEstablished = defaults.bool(forKey: groupStoreEstablishedKey)
            if groupEstablished {
                storeLog.fault("Group store unavailable but it is the established source of truth — refusing to revert to the pre-migration legacy store; using in-memory store with warning")
                return inMemoryFallback()
            }

            // Never established: the group file is at most a just-landed migration
            // copy (or a stale suspect copy from an earlier failed launch) with no
            // app writes. Quarantine it so the next launch re-attempts migration,
            // then fall through to open the intact, never-deleted legacy store
            // read-write — recovering the user's data instead of stranding them.
            if existingLegacyStoreURL(candidates: legacyCandidates, fileManager: fileManager) != nil {
                quarantineSuspectGroupStore(at: url, fileManager: fileManager)
                storeLog.error("Copied group store unopenable and never established — quarantined the suspect copy; falling back to the intact legacy store")
            } else {
                storeLog.error("Group store never established and no legacy store to recover — falling back to legacy store location")
            }
        }

        // Legacy read-write fallback: reached only when the migration copy failed
        // (selection == .legacy) or the group store was never established, so no
        // divergent group data exists to strand.
        let legacyURL: URL
        if case .legacy(let url) = selection {
            legacyURL = url
        } else {
            legacyURL = existingLegacyStoreURL(candidates: legacyCandidates, fileManager: fileManager)
                ?? legacyCandidates.last
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

        return inMemoryFallback()
    }

    /// Move a suspect (copied-but-never-successfully-opened) group store and its
    /// sidecars out of the way so the next launch's `selectStoreURL` sees no group
    /// file and re-attempts migration from the intact legacy store. The suspect
    /// files are renamed (not deleted) into a timestamped `.quarantine` sibling so
    /// nothing is destroyed — if the copy was actually salvageable it can still be
    /// recovered manually. Best-effort: failures here don't block the legacy open.
    private static func quarantineSuspectGroupStore(
        at groupURL: URL,
        fileManager: FileManager = .default
    ) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-shm", "-wal"] {
            let src = URL(fileURLWithPath: groupURL.path + suffix)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: groupURL.path + suffix + ".quarantine-\(stamp)")
            do {
                if fileManager.fileExists(atPath: dst.path) {
                    try fileManager.removeItem(at: dst)
                }
                try fileManager.moveItem(at: src, to: dst)
            } catch {
                storeLog.error("Failed to quarantine suspect group store file \(src.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// In-memory container of last resort, carrying the user-visible
    /// "changes won't be saved" warning. Used when no on-disk store can be
    /// opened safely — including the case where the group store (the source of
    /// truth) is temporarily unopenable, so we warn rather than silently revert
    /// to a divergent legacy store.
    private static func inMemoryFallback() -> ContainerResult {
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
    ///
    /// A read-only (`allowsSave: false`) store CANNOT run a migration — an in-place
    /// migration must write the store, which the configuration forbids. So when the
    /// on-disk store is behind this build's schema (the post-update window before
    /// the user has cold-launched the app, which performs the automatic lightweight
    /// migration on the group store), `ModelContainer` throws here; the caller (the
    /// commute-ETA intent) catches it and steers the user to open the app once to
    /// finish updating. Once the app has migrated, this open succeeds against the
    /// now-current store. (No explicit migration plan would change this — see
    /// `SteddiSchema` for why the schema is unversioned.)
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
