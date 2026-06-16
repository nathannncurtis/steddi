import Testing
import Foundation
import SwiftData
@testable import Steddi

/// Forward-compat hardening for persisted enum properties. `Route.source` /
/// `.direction`, `Trip.flowMode`, and `CommuteTrip.direction` are stored as raw
/// String columns with computed typed accessors (mirroring `RoadCondition.kind`)
/// so a future build that renames or drops an enum case can't brick existing
/// rows: an unknown stored raw value degrades to a safe default instead of
/// failing the whole row's decode. These tests pin that behavior.
@Suite("Persisted enum raw-value fallback")
struct PersistedEnumFallbackTests {

    // MARK: Route.source

    @Test("Unknown RouteSource raw degrades to .recorded, not a decode failure")
    func routeSourceUnknownDegrades() {
        let route = Route(rank: 0, encodedPolyline: "abc")
        route.sourceRaw = "suggestedV2FromANewerBuild"
        #expect(route.source == .recorded)
    }

    @Test("Route.source setter round-trips through the raw column")
    func routeSourceRoundTrips() {
        let route = Route(rank: 0, encodedPolyline: "abc")
        route.source = .planned
        #expect(route.sourceRaw == "planned")
        #expect(route.source == .planned)
    }

    // MARK: Route.direction

    @Test("Unknown Route direction raw degrades to .originToDestination")
    func routeDirectionUnknownDegrades() {
        let route = Route(rank: 0, encodedPolyline: "abc")
        route.directionRaw = "diagonalFromANewerBuild"
        #expect(route.direction == .originToDestination)
    }

    @Test("Route.direction setter round-trips through the raw column")
    func routeDirectionRoundTrips() {
        let route = Route(rank: 0, encodedPolyline: "abc")
        route.direction = .destinationToOrigin
        #expect(route.directionRaw == "destinationToOrigin")
        #expect(route.direction == .destinationToOrigin)
    }

    // MARK: Trip.flowMode

    @Test("Unknown TripFlowMode raw degrades to .continuous")
    func tripFlowModeUnknownDegrades() {
        let trip = Trip(name: "Errands")
        trip.flowModeRaw = "semiAutoFromANewerBuild"
        #expect(trip.flowMode == .continuous)
    }

    @Test("Trip.flowMode setter round-trips through the raw column")
    func tripFlowModeRoundTrips() {
        let trip = Trip(name: "Errands")
        trip.flowMode = .manual
        #expect(trip.flowModeRaw == "manual")
        #expect(trip.flowMode == .manual)
    }

    // MARK: CommuteTrip.direction

    @Test("Unknown CommuteTrip direction raw degrades to .originToDestination")
    func commuteTripDirectionUnknownDegrades() {
        let commute = Commute(name: "Work")
        let log = CommuteTrip(commute: commute, direction: .destinationToOrigin)
        log.directionRaw = "loopFromANewerBuild"
        #expect(log.direction == .originToDestination)
    }

    @Test("CommuteTrip.direction setter round-trips through the raw column")
    func commuteTripDirectionRoundTrips() {
        let commute = Commute(name: "Work")
        let log = CommuteTrip(commute: commute, direction: .originToDestination)
        log.direction = .destinationToOrigin
        #expect(log.directionRaw == "destinationToOrigin")
        #expect(log.direction == .destinationToOrigin)
    }

    // MARK: Persistence round-trip through SwiftData

    @Test("Raw enum columns survive a SwiftData store round-trip")
    func storeRoundTrip() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: config)
        let context = ModelContext(container)

        let route = Route(rank: 1, encodedPolyline: "xyz", source: .planned, direction: .destinationToOrigin)
        context.insert(route)
        try context.save()

        let fetched = try #require(
            try context.fetch(FetchDescriptor<Route>()).first
        )
        #expect(fetched.source == .planned)
        #expect(fetched.direction == .destinationToOrigin)
    }
}

// MARK: - Versioned-schema rename proof (SwiftData's intended migration path)

/// BEFORE snapshot: the twin's enum raw column under its PRE-rename on-disk name
/// `oldDirection`, natively bound (no `originalName`) — the shape a pre-24c7c8a store
/// was written under.
enum RenameSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [RenameTwin.self] }

    @Model
    final class RenameTwin {
        var id: UUID = UUID()
        var oldDirection: String = CommuteDirection.originToDestination.rawValue
        init(direction: CommuteDirection) { self.id = UUID(); self.oldDirection = direction.rawValue }
    }
}

/// AFTER snapshot: the SAME entity (`RenameTwin`) with the column renamed to
/// `directionRaw` carrying `@Attribute(originalName: "oldDirection")` + a declared
/// default — the EXACT fix shape applied to `Route.directionRaw` (renamed from
/// `direction`), `Route.sourceRaw`, `Trip.flowModeRaw`, and `CommuteTrip.directionRaw`.
enum RenameSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [RenameTwin.self] }

    @Model
    final class RenameTwin {
        var id: UUID = UUID()
        @Attribute(originalName: "oldDirection")
        var directionRaw: String = CommuteDirection.originToDestination.rawValue
        var direction: CommuteDirection {
            get { CommuteDirection(rawValue: directionRaw) ?? .originToDestination }
            set { directionRaw = newValue.rawValue }
        }
        init(direction: CommuteDirection) { self.id = UUID(); self.directionRaw = direction.rawValue }
    }
}

/// A real `SchemaMigrationPlan` with a single `.lightweight` V1→V2 stage. The two
/// versions are DISTINCT nested `@Model` classes (frozen snapshots), so the renamed
/// attribute is a genuine diff SwiftData must reconcile via the `originalName` hint —
/// not the no-op trap (two versions referencing one live class) the production
/// `SteddiMigrationPlan` doc warns about.
enum RenameMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [RenameSchemaV1.self, RenameSchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: RenameSchemaV1.self, toVersion: RenameSchemaV2.self)]
    }
}

/// Proves the `@Attribute(originalName:)` + declared-default rename hint applied to the
/// four live enum raw columns carries pre-existing data forward — using SwiftData's
/// OWN intended migration mechanism (`VersionedSchema` + `SchemaMigrationPlan`).
///
/// ## Why this exists
///
/// Commit 24c7c8a refactored four already-shipped, already-persisted enum properties
/// into raw-`String` columns, RENAMING their on-disk attribute:
/// `Route.source`→`sourceRaw`, `Route.direction`→`directionRaw`,
/// `Trip.flowMode`→`flowModeRaw`, `CommuteTrip.direction`→`directionRaw`. A column
/// rename is NOT additive: without an `@Attribute(originalName:)` hint, migration sees
/// the old column dropped and a new required column added, blanking every existing
/// route's source/direction, every trip's flow mode, and every logged commute trip's
/// direction (a saved return-trip route would silently flip to `.originToDestination`).
/// The fix adds `@Attribute(originalName: "<old name>")` + a declared default to each.
///
/// ## How this proves it without crashing the run
///
/// We can't reopen a store written by one live `@Model` under a second `@Model` of the
/// same entity name in one process — that SIGSEGVs the run (`SteddiSchemaMigrationTests`
/// documents this), and mutating a `Schema.Attribute`'s name at runtime doesn't redirect
/// the compiled setter (verified: the value never lands). SwiftData's purpose-built path
/// for exactly this — a renamed attribute — is a `SchemaMigrationPlan` over two frozen
/// `VersionedSchema` snapshots. `RenameTwin` is captured under V1 (pre-rename column
/// `oldDirection`, no hint) and V2 (the fix shape: `directionRaw` +
/// `@Attribute(originalName: "oldDirection")`), as two distinct nested classes sharing
/// the entity name — the canonical frozen-snapshot pattern, never registered
/// simultaneously in one container. We write a store under V1, then reopen it under V2
/// WITH `RenameMigrationPlan`'s lightweight stage, and assert the pre-rename value
/// survives. If the `originalName` hint were absent (or wrong), the lightweight stage
/// would drop `oldDirection` and the value would reset to the default `.originToDestination`.
@Suite("Renamed enum raw column migrates its pre-rename value via originalName")
struct RawColumnRenameMigrationTests {

    private func makeTempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawColumnRenameMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Rename.store")
    }

    @Test("A value persisted under the pre-rename column survives a lightweight originalName migration")
    func renamedColumnCarriesDataForward() throws {
        let url = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // 1. Write under V1 (column `oldDirection`), using a NON-default value so a
        //    blanked/defaulted column after migration would be detectable — the saved
        //    return-trip (.destinationToOrigin) route case that must not silently flip.
        let twinID: UUID
        do {
            let v1 = try ModelContainer(
                for: Schema(versionedSchema: RenameSchemaV1.self),
                migrationPlan: RenameMigrationPlan.self,
                configurations: [ModelConfiguration(url: url)]
            )
            let ctx = ModelContext(v1)
            let twin = RenameSchemaV1.RenameTwin(direction: .destinationToOrigin)
            ctx.insert(twin)
            try ctx.save()
            twinID = twin.id
        }

        // 2. Reopen the SAME file under V2 (column `directionRaw` +
        //    `@Attribute(originalName: "oldDirection")`) WITH the lightweight migration
        //    plan. SwiftData must map the old `oldDirection` column onto `directionRaw`.
        let v2 = try ModelContainer(
            for: Schema(versionedSchema: RenameSchemaV2.self),
            migrationPlan: RenameMigrationPlan.self,
            configurations: [ModelConfiguration(url: url)]
        )
        let ctx = ModelContext(v2)
        let twins = try ctx.fetch(FetchDescriptor<RenameSchemaV2.RenameTwin>())
        #expect(twins.count == 1)
        let migrated = try #require(twins.first { $0.id == twinID })

        // The decisive guarantee: the pre-rename value carried forward. Without the
        // `originalName` hint, this would be the default `.originToDestination` (the
        // reported data loss — a saved return-trip route silently flipping direction).
        #expect(migrated.directionRaw == "destinationToOrigin")
        #expect(migrated.direction == .destinationToOrigin)
    }

    // MARK: Live-model schema-metadata + on-disk round-trip

    /// The fix is only data-preserving if each renamed `*Raw` attribute actually carries
    /// its `@Attribute(originalName:)` hint into SwiftData's built schema. This reads the
    /// live `ModelStoreLocator.schema` and asserts the four renamed columns map back to
    /// their pre-24c7c8a on-disk names — the wiring the migration above proves the
    /// mechanic for. A regression that dropped any `originalName` would fail here.
    @Test("Live renamed columns declare the correct originalName in the built schema")
    func liveColumnsDeclareOriginalName() throws {
        let schema = ModelStoreLocator.schema
        // entity name → (current attribute name → expected pre-rename originalName)
        let expected: [String: [String: String]] = [
            "Route": ["sourceRaw": "source", "directionRaw": "direction"],
            "Trip": ["flowModeRaw": "flowMode"],
            "CommuteTrip": ["directionRaw": "direction"]
        ]
        for (entityName, mapping) in expected {
            let entity = try #require(schema.entities.first { $0.name == entityName },
                                      "missing entity \(entityName)")
            for (attrName, expectedOriginal) in mapping {
                let attr = try #require(entity.attributes.first { $0.name == attrName },
                                        "missing attribute \(entityName).\(attrName)")
                #expect(attr.originalName == expectedOriginal,
                        "\(entityName).\(attrName) originalName was \(attr.originalName), expected \(expectedOriginal)")
            }
        }
    }

    /// Companion check that adding `@Attribute(originalName:)` + a declared default did
    /// not alter how the CURRENT schema reads/writes these four columns: each live model
    /// round-trips its non-default enum value through a real on-disk store.
    @Test("Live Route/Trip/CommuteTrip enum columns round-trip through an on-disk store")
    func liveModelsRoundTripOnDisk() throws {
        let url = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let routeID: UUID
        let tripID: UUID
        let logID: UUID
        do {
            let container = try ModelContainer(
                for: ModelStoreLocator.schema,
                configurations: [ModelConfiguration(url: url)]
            )
            let ctx = ModelContext(container)
            let route = Route(rank: 0, encodedPolyline: "back",
                              source: .planned, direction: .destinationToOrigin)
            let trip = Trip(name: "Errands", flowMode: .manual)
            let commute = Commute(name: "Work")
            let log = CommuteTrip(commute: commute, direction: .destinationToOrigin)
            ctx.insert(route); ctx.insert(trip); ctx.insert(commute); ctx.insert(log)
            try ctx.save()
            routeID = route.id; tripID = trip.id; logID = log.id
        }

        let reopened = try ModelContainer(
            for: ModelStoreLocator.schema,
            configurations: [ModelConfiguration(url: url)]
        )
        let ctx = ModelContext(reopened)

        let route = try #require(try ctx.fetch(FetchDescriptor<Route>()).first { $0.id == routeID })
        #expect(route.source == .planned)
        #expect(route.direction == .destinationToOrigin)

        let trip = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first { $0.id == tripID })
        #expect(trip.flowMode == .manual)

        let log = try #require(try ctx.fetch(FetchDescriptor<CommuteTrip>()).first { $0.id == logID })
        #expect(log.direction == .destinationToOrigin)
    }
}
