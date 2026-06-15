import Foundation
import SwiftData

/// Versioned schema + migration plan for the SwiftData store.
///
/// Before this existed, every `ModelContainer(for:)` call relied on SwiftData's
/// implicit lightweight migration with no declared schema versions. That is fine
/// for the read-write app container (it can migrate the on-disk store in place),
/// but it leaves two gaps the explicit plan closes:
///
/// 1. **Determinism / reviewability.** Additive schema changes (new columns with
///    defaults — e.g. `Commute.notificationsEnabled`, `PinnedLocation.category`,
///    the summary fields on `DriveRecord`) are now captured as named, versioned
///    stages, so a migration is a reviewable diff instead of implicit behavior
///    that silently changes between builds.
///
/// 2. **A single source of truth for "the current schema."** `ModelStoreLocator`
///    builds every container from `SteddiMigrationPlan.currentSchema.models`, so
///    the app container, the read-only shared container (Siri intent / extensions),
///    and the in-memory fallback can never drift apart.
///
/// Note on read-only stores: a `SchemaMigrationPlan` does NOT let a read-only
/// (`allowsSave: false`) store run a migration — an in-place migration must WRITE
/// the store, which a read-only configuration forbids (verified: CoreData 134110
/// "attempt to write a readonly database"). So the plan's value is for the
/// read-write app container: a deterministic, declared upgrade performed once on
/// next launch. The read-only consumer (the commute-ETA intent) reads the store
/// only AFTER the app has migrated it; until then, opening throws a load error
/// the intent detects and steers the user to open the app —
/// see `ModelStoreLocator.makeReadOnlySharedContainer`.
enum SteddiMigrationPlan: SchemaMigrationPlan {

    static var schemas: [any VersionedSchema.Type] {
        [SteddiSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        // Only one version exists today. Future additive changes add a new
        // `SteddiSchemaV2` and a `.lightweight` stage from V1 → V2 here; a
        // non-lightweight change adds a `.custom` stage instead. Because all
        // changes to date are additive-with-defaults, no stage is needed yet.
        []
    }

    /// The schema the app currently builds containers from.
    static var currentSchema: any VersionedSchema.Type { SteddiSchemaV1.self }
}

/// V1 — the current model graph. Enumerates every `@Model` type the app persists.
/// Keep this in lockstep with the live model definitions; a new persisted model
/// or property is part of V1 only until the first shipped V2 freezes V1's shape.
enum SteddiSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            PinnedLocation.self,
            Commute.self,
            Route.self,
            DriveRecord.self,
            NoGoZone.self,
            CommuteTrip.self,
            Report.self,
            CommuteAnalyticsAggregate.self,
            Trip.self,
            TripStop.self,
            RoadCondition.self,
            CameraReport.self
        ]
    }
}
