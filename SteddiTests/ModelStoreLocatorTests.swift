import Testing
import Foundation
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

    @Test("Nil group container falls back to legacy URL")
    func nilGroupFallsBackToLegacy() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("default.store")

        let selection = ModelStoreLocator.selectStoreURL(groupURL: nil, legacyURL: legacy)
        #expect(selection == .legacy(legacy))
    }

    @Test("Fresh install with no stores picks the group URL")
    func freshInstallPicksGroup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("group/Steddi.store")
        let legacy = dir.appendingPathComponent("legacy/default.store")

        let selection = ModelStoreLocator.selectStoreURL(groupURL: group, legacyURL: legacy)
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

        let selection = ModelStoreLocator.selectStoreURL(groupURL: group, legacyURL: legacy)
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

    @Test("Legacy store without sidecars still migrates the main file")
    func migratesWithoutSidecars() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("group/Steddi.store")
        let legacy = dir.appendingPathComponent("legacy/default.store")
        try writeStore(at: legacy, contents: "solo", sidecars: false)

        let selection = ModelStoreLocator.selectStoreURL(groupURL: group, legacyURL: legacy)
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

        let selection = ModelStoreLocator.selectStoreURL(groupURL: group, legacyURL: legacy)
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

        let selection = ModelStoreLocator.selectStoreURL(groupURL: group, legacyURL: legacy)
        #expect(selection == .legacy(legacy))
        // Legacy store untouched
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "legacy-data")
    }
}

// MARK: - Store URL Tests

@Suite("ModelStoreLocator URLs")
struct ModelStoreLocatorURLTests {

    @Test("Group store URL uses the fixed filename outside Application Support")
    func groupStoreURLInContainer() {
        // On simulator/device with the entitlement this resolves; the store
        // file must sit in the group container, distinct from the legacy path.
        if let url = ModelStoreLocator.groupStoreURL() {
            #expect(url.lastPathComponent == ModelStoreLocator.storeFilename)
            #expect(url != ModelStoreLocator.legacyStoreURL())
        }
    }

    @Test("Legacy store URL is the SwiftData default location")
    func legacyStoreURLDefault() {
        let url = ModelStoreLocator.legacyStoreURL()
        #expect(url.lastPathComponent == "default.store")
        #expect(url.path.contains("Application Support"))
    }
}
