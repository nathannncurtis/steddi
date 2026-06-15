import Testing
import Foundation
import SwiftData
@testable import Steddi

// MARK: - Store Selection Tests

@Suite("ModelStoreLocator.selectStoreURL")
struct ModelStoreLocatorSelectionTests {

    /// Make a unique temp directory with optional legacy/group store files.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreLocatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeStore(at url: URL, contents: String, sidecars: Bool = true) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        if sidecars {
            try Data("\(contents)-shm".utf8).write(to: URL(fileURLWithPath: url.path + "-shm"))
            try Data("\(contents)-wal".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
        }
    }

    @Test("Nil group container falls back to the existing legacy store")
    func nilGroupFallsBackToLegacy() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("default.store")
        try writeStore(at: legacy, contents: "legacy-data")

        let selection = ModelStoreLocator.selectStoreURL(groupURL: nil, legacyCandidates: [legacy])
        #expect(selection == .legacy(legacy))
    }

    @Test("Nil group container with no stores falls back to the last candidate")
    func nilGroupNoStoresFallsBackToLastCandidate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let primary = dir.appendingPathComponent("group-legacy/default.store")
        let sandbox = dir.appendingPathComponent("sandbox/default.store")

        let selection = ModelStoreLocator.selectStoreURL(
            groupURL: nil,
            legacyCandidates: [primary, sandbox]
        )
        #expect(selection == .legacy(sandbox))
    }

    @Test("Fresh install with no stores picks the group URL")
    func freshInstallPicksGroup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("group/Steddi.store")
        let legacy = dir.appendingPathComponent("legacy/default.store")

        let selection = ModelStoreLocator.selectStoreURL(groupURL: group, legacyCandidates: [legacy])
        #expect(selection == .group(group))
        // Nothing to migrate — no file should appear
        #expect(!FileManager.default.fileExists(atPath: group.path))
    }

    @Test("Legacy store is copied to group location, original kept")
    func migratesLegacyStore() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("group/Steddi.store")
        let legacy = dir.appendingPathComponent("legacy/default.store")
        try writeStore(at: legacy, contents: "legacy-data")

        let selection = ModelStoreLocator.selectStoreURL(groupURL: group, legacyCandidates: [legacy])
        #expect(selection == .group(group))

        // All three files copied
        #expect(try String(contentsOf: group, encoding: .utf8) == "legacy-data")
        #expect(FileManager.default.fileExists(atPath: group.path + "-shm"))
        #expect(FileManager.default.fileExists(atPath: group.path + "-wal"))

        // Legacy store untouched
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: legacy.path + "-shm"))
        #expect(FileManager.default.fileExists(atPath: legacy.path + "-wal"))
    }

    @Test("First existing legacy candidate wins")
    func firstExistingCandidateWins() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("group/Steddi.store")
        // Primary candidate (group-container default location) missing,
        // secondary (sandbox) present.
        let primary = dir.appendingPathComponent("group-legacy/default.store")
        let sandbox = dir.appendingPathComponent("sandbox/default.store")
        try writeStore(at: sandbox, contents: "sandbox-data")

        let selection = ModelStoreLocator.selectStoreURL(
            groupURL: group,
            legacyCandidates: [primary, sandbox]
        )
        #expect(selection == .group(group))
        #expect(try String(contentsOf: group, encoding: .utf8) == "sandbox-data")
    }

    @Test("Primary legacy candidate preferred over later ones")
    func primaryCandidatePreferred() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("group/Steddi.store")
        let primary = dir.appendingPathComponent("group-legacy/default.store")
        let sandbox = dir.appendingPathComponent("sandbox/default.store")
        try writeStore(at: primary, contents: "primary-data")
        try writeStore(at: sandbox, contents: "sandbox-data")

        let selection = ModelStoreLocator.selectStoreURL(
            groupURL: group,
            legacyCandidates: [primary, sandbox]
        )
        #expect(selection == .group(group))
        #expect(try String(contentsOf: group, encoding: .utf8) == "primary-data")
    }

    @Test("Migration is idempotent across repeated launches")
    func migrationIsIdempotent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("group/Steddi.store")
        let legacy = dir.appendingPathComponent("legacy/default.store")
        try writeStore(at: legacy, contents: "legacy-data")

        _ = ModelStoreLocator.selectStoreURL(groupURL: group, legacyCandidates: [legacy])
        // Simulate the app writing to the migrated store, then a relaunch.
        try Data("group-data-after-use".utf8).write(to: group)
        let second = ModelStoreLocator.selectStoreURL(groupURL: group, legacyCandidates: [legacy])

        #expect(second == .group(group))
        // Relaunch must not re-copy over live data.
        #expect(try String(contentsOf: group, encoding: .utf8) == "group-data-after-use")
        // Legacy store still never deleted.
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("Legacy store without sidecars still migrates the main file")
    func migratesWithoutSidecars() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("group/Steddi.store")
        let legacy = dir.appendingPathComponent("legacy/default.store")
        try writeStore(at: legacy, contents: "solo", sidecars: false)

        let selection = ModelStoreLocator.selectStoreURL(groupURL: group, legacyCandidates: [legacy])
        #expect(selection == .group(group))
        #expect(try String(contentsOf: group, encoding: .utf8) == "solo")
        #expect(!FileManager.default.fileExists(atPath: group.path + "-shm"))
        #expect(!FileManager.default.fileExists(atPath: group.path + "-wal"))
    }

    @Test("Existing group store wins and is not overwritten by legacy")
    func existingGroupStoreNotOverwritten() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("group/Steddi.store")
        let legacy = dir.appendingPathComponent("legacy/default.store")
        try writeStore(at: group, contents: "group-data")
        try writeStore(at: legacy, contents: "legacy-data")

        let selection = ModelStoreLocator.selectStoreURL(groupURL: group, legacyCandidates: [legacy])
        #expect(selection == .group(group))
        #expect(try String(contentsOf: group, encoding: .utf8) == "group-data")
    }

    @Test("Copy failure falls back to legacy URL")
    func copyFailureFallsBackToLegacy() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("legacy/default.store")
        try writeStore(at: legacy, contents: "legacy-data")

        // Group parent path is an existing *file*, so createDirectory fails.
        let blocker = dir.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocker)
        let group = blocker.appendingPathComponent("nested/Steddi.store")

        let selection = ModelStoreLocator.selectStoreURL(groupURL: group, legacyCandidates: [legacy])
        #expect(selection == .legacy(legacy))
        // Legacy store untouched
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "legacy-data")
    }

    @Test("Copy staging leaves no temporary directories behind")
    func copyLeavesNoStagingBehind() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("group/Steddi.store")
        let legacy = dir.appendingPathComponent("legacy/default.store")
        try writeStore(at: legacy, contents: "legacy-data")

        try ModelStoreLocator.copyStoreFiles(from: legacy, to: group)

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: group.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".store-migration") }
        #expect(leftovers.isEmpty)
        #expect(try String(contentsOf: group, encoding: .utf8) == "legacy-data")
    }
}

// MARK: - Store URL Tests

@Suite("ModelStoreLocator URLs")
struct ModelStoreLocatorURLTests {

    @Test("Group store URL uses the fixed filename outside Application Support")
    func groupStoreURLInContainer() {
        // On simulator/device with the entitlement this resolves; the store
        // file must sit in the group container, distinct from the legacy paths.
        if let url = ModelStoreLocator.groupStoreURL() {
            #expect(url.lastPathComponent == ModelStoreLocator.storeFilename)
            #expect(!ModelStoreLocator.legacyStoreCandidates().contains(url))
        }
    }

    @Test("Primary legacy candidate is the group container's default store")
    func primaryLegacyCandidateIsGroupDefaultStore() throws {
        // Regression test for the upgrade data-loss bug: with an app-group
        // entitlement, SwiftData's default ModelContainer lives at
        // <group>/Library/Application Support/default.store — that path MUST
        // be the first legacy candidate or existing installs never migrate.
        let groupContainer = try #require(
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ModelStoreLocator.appGroupIdentifier
            )
        )
        let candidates = ModelStoreLocator.legacyStoreCandidates()
        let primary = try #require(candidates.first)

        let expected = groupContainer
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("default.store")
        #expect(primary.standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    @Test("Sandbox Application Support default store is kept as a fallback candidate")
    func sandboxCandidateKeptAsFallback() {
        let sandbox = URL.applicationSupportDirectory.appendingPathComponent("default.store")
        let candidates = ModelStoreLocator.legacyStoreCandidates()
        #expect(candidates.last?.standardizedFileURL.path == sandbox.standardizedFileURL.path)
        #expect(candidates.allSatisfy { $0.lastPathComponent == "default.store" })
    }
}

// MARK: - Read-Only Store Selection Tests

@Suite("ModelStoreLocator.readOnlyStoreURL")
struct ModelStoreLocatorReadOnlyTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreLocatorReadOnlyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Prefers the group store when it exists")
    func prefersGroupStore() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("Steddi.store")
        let legacy = dir.appendingPathComponent("default.store")
        try Data("g".utf8).write(to: group)
        try Data("l".utf8).write(to: legacy)

        let url = ModelStoreLocator.readOnlyStoreURL(groupURL: group, legacyCandidates: [legacy])
        #expect(url == group)
    }

    @Test("Falls back to the legacy store before the app's first post-update launch")
    func fallsBackToLegacyStore() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("Steddi.store")
        let legacy = dir.appendingPathComponent("default.store")
        try Data("l".utf8).write(to: legacy)

        let url = ModelStoreLocator.readOnlyStoreURL(groupURL: group, legacyCandidates: [legacy])
        #expect(url == legacy)
    }

    @Test("Returns nil when no store exists anywhere")
    func nilWhenNothingExists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("Steddi.store")
        let legacy = dir.appendingPathComponent("default.store")

        let url = ModelStoreLocator.readOnlyStoreURL(groupURL: group, legacyCandidates: [legacy])
        #expect(url == nil)
    }
}

// MARK: - Migration Plan / Read-Only Newer-Store Tests

@Suite("ModelStoreLocator migration plan")
struct ModelStoreLocatorMigrationTests {

    private func makeTempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreLocatorMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Steddi.store")
    }

    @Test("Migration plan exposes the current versioned schema")
    func planExposesCurrentSchema() {
        #expect(ModelStoreLocator.migrationPlan is SteddiMigrationPlan.Type)
        // The container schema is built from the plan's current versioned schema,
        // so the two can never drift.
        #expect(ModelStoreLocator.schema.entities.count == SteddiSchemaV1.models.count)
        #expect(SteddiMigrationPlan.schemas.count == 1)
    }

    /// A store written by the current (read-write) schema reopens read-only with
    /// the migration plan and serves a fetch — the healthy same-schema path the
    /// commute-ETA intent depends on.
    @Test("Read-only container opens a store written by the current schema")
    func readOnlyOpensCurrentSchemaStore() throws {
        let url = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Write with the full app schema + plan.
        do {
            let rw = try ModelContainer(
                for: ModelStoreLocator.schema,
                migrationPlan: ModelStoreLocator.migrationPlan,
                configurations: [ModelConfiguration(url: url)]
            )
            let ctx = ModelContext(rw)
            ctx.insert(Commute(name: "Work"))
            try ctx.save()
        }

        // Reopen read-only with the plan and confirm a fetch succeeds.
        let ro = try ModelContainer(
            for: ModelStoreLocator.schema,
            migrationPlan: ModelStoreLocator.migrationPlan,
            configurations: [ModelConfiguration(url: url, allowsSave: false)]
        )
        let commutes = try ModelContext(ro).fetch(FetchDescriptor<Commute>())
        #expect(commutes.count == 1)
        #expect(commutes.first?.name == "Work")
    }

    /// Read-only stores cannot migrate in place — that's an unavoidable SwiftData
    /// constraint (an in-place migration must WRITE the store). This pins the
    /// contract the commute-ETA intent depends on: when the on-disk store needs a
    /// migration the read-only container CANNOT perform, opening it throws a
    /// distinguishable load error at OPEN time (CoreData 134110, surfaced as
    /// SwiftDataError.loadIssueModelContainer) rather than opening and then
    /// silently returning an empty result set. The migration plan does not — and
    /// cannot — change this; the read-write app container performs the real
    /// upgrade on next launch, after which the read-only open succeeds.
    ///
    /// Simulated by writing a store with the full schema, then opening it
    /// read-only with a schema that omits an entity (the shape SwiftData treats
    /// as "needs migration"). The throw is the seam the intent keys off of.
    @Test("Read-only open of a store needing migration throws instead of silently emptying")
    func readOnlyMigrationNeededThrows() throws {
        let url = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Writer: the full current schema (all model types).
        do {
            let writer = try ModelContainer(
                for: ModelStoreLocator.schema,
                migrationPlan: ModelStoreLocator.migrationPlan,
                configurations: [ModelConfiguration(url: url)]
            )
            let ctx = ModelContext(writer)
            ctx.insert(Commute(name: "Work"))
            try ctx.save()
        }

        // Reader: a schema that differs from what's on disk (omits entities), so
        // SwiftData wants to migrate — which a read-only store can't do.
        let mismatchedSchema = Schema([
            PinnedLocation.self,
            Commute.self,
            Route.self,
            DriveRecord.self,
            NoGoZone.self,
            CommuteTrip.self
        ])
        #expect(throws: (any Error).self) {
            _ = try ModelContainer(
                for: mismatchedSchema,
                configurations: [ModelConfiguration(url: url, allowsSave: false)]
            )
        }
    }
}
