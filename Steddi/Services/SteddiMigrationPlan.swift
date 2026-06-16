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
        [SteddiSchemaV1.self, SteddiSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        // V1 → V2 adds the explicit `Commute.driveRecords` ↔ `DriveRecord.associatedCommute`
        // inverse relationship (with a `.nullify` delete rule). This is purely
        // additive at the storage layer — `DriveRecord.associatedCommute` was
        // already a persisted to-one relationship; V2 only declares the matching
        // back-reference SwiftData needs to propagate the delete rule. The new
        // `driveRecords` to-many is empty/nil for every existing row, so a
        // lightweight migration upgrades the store in place with no data
        // transformation. A non-lightweight change would use a `.custom` stage.
        [
            .lightweight(
                fromVersion: SteddiSchemaV1.self,
                toVersion: SteddiSchemaV2.self
            )
        ]
    }

    /// The schema the app currently builds containers from.
    static var currentSchema: any VersionedSchema.Type { SteddiSchemaV2.self }
}

/// V1 — the original model graph, frozen at first ship. Enumerates every `@Model`
/// type the app persisted in V1. Do NOT edit V1's shape; new persisted models or
/// relationships go into a later version (V2+) so each migration is a real diff.
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

/// V2 — adds the explicit `Commute.driveRecords` ↔ `DriveRecord.associatedCommute`
/// inverse relationship with a `.nullify` delete rule, so deleting a Commute nulls
/// each associated drive's back-reference instead of leaving a dangling pointer to
/// an invalidated model. The persisted model-type set is unchanged from V1 — only
/// the relationship declaration changed — so the V1 → V2 stage is lightweight.
enum SteddiSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

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
