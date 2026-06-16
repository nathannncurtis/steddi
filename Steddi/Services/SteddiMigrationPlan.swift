import Foundation
import SwiftData

/// The app's SwiftData schema, and a note on how it migrates.
///
/// ## Why there is no `SchemaMigrationPlan` here
///
/// Every Steddi store that has ever shipped was created by a plain, *unversioned*
/// `ModelContainer(for: Schema([...]))`. None carries a `Schema.Version` stamp on
/// disk. A `SchemaMigrationPlan` migrates *from a declared `VersionedSchema`* — its
/// `from` boundary must match a version that was actually written to the store.
/// Since no store on disk was ever stamped "1.0.0" (or any version), a versioned
/// plan has no real `from` snapshot to migrate out of: the version boundary is
/// fiction, and the framework just falls back to its automatic lightweight
/// migration anyway. A retrofitted plan therefore adds false confidence — a
/// reviewable-looking diff that migrates nothing — without changing runtime
/// behavior. (A prior version of this file did exactly that: it declared
/// `SteddiSchemaV1` and `SteddiSchemaV2`, but both referenced the *same live*
/// `@Model` classes, so the two versions compiled to identical schema hashes and
/// the `.lightweight(V1 → V2)` stage was a no-op.)
///
/// ## What actually upgrades the store: automatic lightweight migration
///
/// Every schema change Steddi has shipped is **purely additive** and is handled by
/// SwiftData's automatic lightweight migration when the container opens — no
/// explicit plan required:
///
///   * `Commute.notificationsEnabled` / `quietHoursStart` / `quietHoursEnd` /
///     `notificationLeadMinutes` — new properties with defaults.
///   * `PinnedLocation.category` — new property whose declared default is "" so
///     lightweight migration stamps "" onto pre-existing rows, which
///     `HomeView.migrateExistingPinsToCategories()` then backfills by icon (a
///     non-empty default would stamp a concrete category and defeat that backfill).
///   * `DriveRecord.totalDurationSeconds` / `maxSpeedMps` / `averageSpeedMps` /
///     `trafficDurationSeconds` — new optional properties (nil for old rows).
///   * The `Commute.driveRecords` ↔ `DriveRecord.associatedCommute` **inverse
///     relationship** (with a `.nullify` delete rule). `associatedCommute` was
///     *already* a persisted to-one relationship; this change only declares the
///     matching back-reference SwiftData needs to propagate the delete rule. The
///     new `driveRecords` to-many is empty/nil for every existing row, so opening a
///     pre-inverse store under the current schema requires no data transformation.
///
/// `SteddiSchemaMigrationTests` (in `SteddiTests/ModelStoreLocatorTests.swift`)
/// proves the inverse-relationship case end to end: it writes a store under a
/// derived *pre-inverse* snapshot of a twin model graph (`MigParent`/`MigChild`,
/// the shape `DriveRecord.associatedCommute` had before the inverse was added),
/// reopens the same file under the current (inverse + `.nullify`) schema with no
/// `SchemaMigrationPlan`, and asserts the store opens via automatic lightweight
/// migration with its data intact and the `.nullify` rule then live. The live
/// `Commute`/`DriveRecord` delete-nullify behavior is additionally covered by
/// `CommuteDriveRecordRelationshipTests` in the same file.
///
/// ## When a real plan WILL be needed
///
/// A `SchemaMigrationPlan` is only worth introducing for a change automatic
/// lightweight migration cannot do on its own — e.g. renaming a property,
/// splitting/merging entities, or transforming stored values. At that point, the
/// *first* `VersionedSchema` must be a genuine **frozen snapshot** of the model
/// graph as it exists on disk today (independent nested `@Model` types, NOT
/// references to the live classes — otherwise editing a live model silently mutates
/// the "old" version and defeats the diff). Capture that frozen baseline, declare a
/// real `.custom`/`.lightweight` stage to the new version, and pass the plan to the
/// `ModelContainer(for:migrationPlan:...)` calls in `ModelStoreLocator`.
///
/// Until then, the honest answer is: the schema is unversioned and additive changes
/// migrate automatically. `ModelStoreLocator.schema` is the single source of truth
/// for the current model graph.
enum SteddiSchema {

    /// Every `@Model` type the app persists. Built once here so every container
    /// (the read-write app store, the read-only shared store for the Siri intent /
    /// extensions, and the in-memory fallback) opens the exact same model graph and
    /// can never drift apart.
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

    /// The current model-graph schema. `ModelStoreLocator` builds every container
    /// from this, so the app container and the read-only shared container can never
    /// drift apart.
    static var current: Schema { Schema(models) }
}
