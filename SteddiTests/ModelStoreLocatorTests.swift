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

// MARK: - Schema / Read-Only Newer-Store Tests

@Suite("ModelStoreLocator migration plan")
struct ModelStoreLocatorMigrationTests {

    private func makeTempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreLocatorMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Steddi.store")
    }

    /// The container schema IS `SteddiSchema.current` — a single source of truth, so
    /// every container (app, read-only shared, in-memory fallback) opens the exact
    /// same model graph and they can never drift. There is no explicit
    /// `SchemaMigrationPlan`: shipped changes are additive and migrate via
    /// SwiftData's automatic lightweight migration. (Behavior — not the shape of a
    /// plan — is verified by `SteddiSchemaMigrationTests` below.)
    @Test("Container schema is the single SteddiSchema source of truth")
    func schemaIsSingleSourceOfTruth() {
        // The locator's schema and the canonical schema cover the same entities.
        let locatorEntities = Set(ModelStoreLocator.schema.entities.map(\.name))
        let canonicalEntities = Set(SteddiSchema.current.entities.map(\.name))
        #expect(locatorEntities == canonicalEntities)
        // All twelve persisted model types are present.
        #expect(SteddiSchema.models.count == 12)
        #expect(canonicalEntities.count == 12)
        // The entities the inverse-relationship change touches are both in the graph.
        #expect(canonicalEntities.contains("Commute"))
        #expect(canonicalEntities.contains("DriveRecord"))
    }

    /// A store written by the current (read-write) schema reopens read-only with
    /// the migration plan and serves a fetch — the healthy same-schema path the
    /// commute-ETA intent depends on.
    @Test("Read-only container opens a store written by the current schema")
    func readOnlyOpensCurrentSchemaStore() throws {
        let url = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Write with the full app schema.
        do {
            let rw = try ModelContainer(
                for: ModelStoreLocator.schema,
                configurations: [ModelConfiguration(url: url)]
            )
            let ctx = ModelContext(rw)
            ctx.insert(Commute(name: "Work"))
            try ctx.save()
        }

        // Reopen read-only and confirm a fetch succeeds.
        let ro = try ModelContainer(
            for: ModelStoreLocator.schema,
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

// MARK: - Commute ↔ DriveRecord Relationship Tests

@Suite("Commute ↔ DriveRecord inverse relationship")
struct CommuteDriveRecordRelationshipTests {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: config)
        return ModelContext(container)
    }

    /// Deleting a Commute must NULL the associated drive's back-reference (the
    /// `.nullify` rule on the explicit inverse) rather than cascade-deleting the
    /// historical drive or leaving it pointing at an invalidated model. This is the
    /// regression test for the inverse-less dangling-relationship bug.
    @Test("Deleting a Commute nullifies the drive's reference and keeps the drive")
    func deletingCommuteNullifiesDriveReference() throws {
        let context = try makeContext()

        let commute = Commute(name: "Work")
        let drive = DriveRecord(startedAt: Date())
        drive.associatedCommute = commute
        context.insert(commute)
        context.insert(drive)
        try context.save()

        let driveID = drive.id
        #expect(drive.associatedCommute?.id == commute.id)
        // The inverse back-reference is populated from the drive side.
        #expect(commute.driveRecords?.contains { $0.id == driveID } == true)

        context.delete(commute)
        try context.save()

        // The historical drive survives the commute deletion...
        let drives = try context.fetch(FetchDescriptor<DriveRecord>())
        #expect(drives.count == 1)
        let survivor = try #require(drives.first { $0.id == driveID })
        // ...with its reference nulled (no dangling pointer to an invalidated model).
        #expect(survivor.associatedCommute == nil)

        // And the commute is gone.
        let commutes = try context.fetch(FetchDescriptor<Commute>())
        #expect(commutes.isEmpty)
    }
}

// MARK: - Pre-Inverse Schema Snapshot (test fixture)

/// A FROZEN snapshot of the model graph as it shipped BEFORE the
/// `Commute.driveRecords` ↔ `DriveRecord.associatedCommute` inverse relationship
/// existed (i.e. before commit d339f57). This is a real, independent
/// `VersionedSchema` whose nested `@Model` types are NOT the live classes — they
/// reproduce the genuine old on-disk shape, differing from the live models in
/// EXACTLY ONE way:
///
///   * `DriveRecord.associatedCommute` is a plain to-one relationship with NO
///     `inverse:` and NO explicit delete rule (how it was persisted before d339f57).
///   * `Commute` correspondingly has NO `driveRecords` back-reference.
///
/// Every OTHER persisted attribute is reproduced faithfully (same names, same
/// optionality, same scalar types) so the snapshot's store has the same columns a
/// real pre-inverse store had. That faithfulness matters: a non-optional attribute
/// with no default (`DriveRecord.rawGPSPoints`, `wasConverted`; `Commute.name`,
/// `isActive`, …) must already exist in the source store, or the upgrade fails with
/// "missing attribute values on mandatory destination attribute". The snapshot is
/// reduced to just the two entities under test (their relationships to the other ten
/// model types are omitted — those are nullable/to-many and migrate in as nil/empty,
/// the additive case), which keeps the snapshot a valid, self-consistent schema.
///
/// SwiftData derives a nested type's entity name from its SIMPLE name, so
/// `PreInverseSchema.Commute` maps to the same store table ("Commute") as the live
/// `Commute`, and likewise for `DriveRecord`. That is what lets a store WRITTEN with
/// this snapshot be REOPENED under the current live schema — the exact migration
/// path a real user on a pre-inverse build takes.
enum PreInverseSchema: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Commute.self, DriveRecord.self]
    }

    @Model
    final class Commute {
        var id: UUID = UUID()
        var name: String = ""
        var thresholdPercentage: Double = 0.20
        var hardMinuteFloor: Int?
        var isActive: Bool = true
        var createdAt: Date = Date()

        var avoidsTolls: Bool?
        var avoidsHighways: Bool?
        var skipRoutePreview: Bool?

        var scheduleToDestDays: String?
        var scheduleToDestStartHour: Int?
        var scheduleToDestEndHour: Int?
        var scheduleToOriginDays: String?
        var scheduleToOriginStartHour: Int?
        var scheduleToOriginEndHour: Int?

        var notificationsEnabled: Bool = true
        var quietHoursStart: Int?
        var quietHoursEnd: Int?
        var notificationLeadMinutes: Int = 15

        init(name: String) {
            self.id = UUID()
            self.name = name
            self.isActive = true
            self.createdAt = Date()
        }
    }

    @Model
    final class DriveRecord {
        var id: UUID = UUID()
        var startedAt: Date = Date()
        var endedAt: Date?
        // Non-optional, no default — must exist in the source store (this is the
        // column whose absence broke an earlier, unfaithful version of this snapshot).
        var rawGPSPoints: [GPSPoint] = []
        var matchedPolyline: String?
        // Pre-inverse shape: a plain to-one with no `inverse:` and no explicit delete
        // rule — the exact field declaration that shipped before d339f57.
        var associatedCommute: Commute?
        var wasConverted: Bool = false

        var trafficDurationSeconds: Double?
        var totalDurationSeconds: Double?
        var maxSpeedMps: Double?
        var averageSpeedMps: Double?

        init(startedAt: Date = Date()) {
            self.id = UUID()
            self.startedAt = startedAt
            self.rawGPSPoints = []
            self.wasConverted = false
        }
    }
}

// MARK: - Real Pre-Inverse → Current Migration Test

/// The deciding evidence for dropping the versioned plan: a store written under the
/// genuine OLD (pre-inverse) schema must open under the CURRENT schema via automatic
/// lightweight migration, without error or data loss, and the new `.nullify` inverse
/// rule must then work. If this passes with NO explicit `SchemaMigrationPlan`, the
/// plan was unnecessary; if it required one, the test would fail at the reopen.
@Suite("Pre-inverse store migrates to the current schema")
struct SteddiSchemaMigrationTests {

    private func makeTempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SteddiSchemaMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Steddi.store")
    }

    @Test("A pre-inverse store opens under the current schema with data intact and the .nullify rule live")
    func preInverseStoreMigratesAndNullifies() throws {
        let url = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // 1. Write a store under the FROZEN pre-inverse schema (no inverse, no
        //    explicit delete rule) — the shape that shipped before d339f57.
        let driveID: UUID
        let commuteName = "Old Commute"
        do {
            let oldContainer = try ModelContainer(
                for: Schema(versionedSchema: PreInverseSchema.self),
                configurations: [ModelConfiguration(url: url)]
            )
            let ctx = ModelContext(oldContainer)
            let commute = PreInverseSchema.Commute(name: commuteName)
            let drive = PreInverseSchema.DriveRecord(startedAt: Date())
            drive.associatedCommute = commute
            ctx.insert(commute)
            ctx.insert(drive)
            try ctx.save()
            driveID = drive.id
        }

        // 2. Reopen the SAME store file under the CURRENT live schema — exactly what
        //    ModelStoreLocator does — with NO explicit migration plan. Automatic
        //    lightweight migration must upgrade it in place.
        let current = try ModelContainer(
            for: SteddiSchema.current,
            configurations: [ModelConfiguration(url: url)]
        )
        let ctx = ModelContext(current)

        // (i) Opens without error and the pre-existing data survived intact,
        //     including the previously-relationship-only `associatedCommute` link.
        let commutes = try ctx.fetch(FetchDescriptor<Commute>())
        #expect(commutes.count == 1)
        let migratedCommute = try #require(commutes.first)
        #expect(migratedCommute.name == commuteName)

        let drives = try ctx.fetch(FetchDescriptor<DriveRecord>())
        #expect(drives.count == 1)
        let migratedDrive = try #require(drives.first { $0.id == driveID })
        #expect(migratedDrive.associatedCommute?.id == migratedCommute.id)
        // The new inverse back-reference is now populated from the existing link.
        #expect(migratedCommute.driveRecords?.contains { $0.id == driveID } == true)

        // (ii) Deleting the Commute nullifies the drive's `associatedCommute` and the
        //      DriveRecord survives (the .nullify inverse rule, now live post-migration).
        ctx.delete(migratedCommute)
        try ctx.save()

        let survivors = try ctx.fetch(FetchDescriptor<DriveRecord>())
        #expect(survivors.count == 1)
        let survivor = try #require(survivors.first { $0.id == driveID })
        #expect(survivor.associatedCommute == nil)
        #expect(try ctx.fetch(FetchDescriptor<Commute>()).isEmpty)
    }
}
