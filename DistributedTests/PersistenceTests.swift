import Testing
import Foundation
@testable import PuzzleSolver

struct PersistenceTests {
    @Test func rejectsSyncedDirectoriesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("state-path-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["Mobile Documents", "CloudStorage", "Dropbox", "OneDrive - Work", "Google Drive"] {
            let cloud = root.appendingPathComponent(name)
            #expect(throws: (any Error).self) { try StateLock(directory: cloud) }
            #expect(!FileManager.default.fileExists(atPath: cloud.path))
            try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
            let link = root.appendingPathComponent("alias-\(UUID())")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cloud)
            #expect(throws: (any Error).self) { try DurableStore(path: link.appendingPathComponent("client.sqlite").path) }
        }
    }

    @Test func movedDatabaseFailsWithActionableDiagnostic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("state-moved-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("client.sqlite")
        let store = try DurableStore(path: path.path)
        try store.write(["saved": 7])
        let moved = root.appendingPathComponent("client 2.sqlite")
        try FileManager.default.moveItem(at: path, to: moved)
        do {
            try store.write(["saved": 8])
            Issue.record("A moved database accepted a checkpoint")
        } catch let error as StateDatabaseError {
            #expect(error.path == path.path)
            // Apple's system SQLite may return SQLITE_IOERR_VNODE instead of
            // SQLITE_READONLY_DBMOVED. Preserve its actual diagnostic code.
            #expect(error.code == 1032 || error.code == 6922)
            #expect(error.pathChanged)
            #expect(error.description.contains("moved or replaced"))
        }
        let recovered = try DurableStore(path: moved.path)
        #expect(try recovered.read([String: Int].self) == ["saved": 7])
    }

    @Test func maintenanceStorageFailuresAreObserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("state-health-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = DistributedConfig()
        config.stateDirectory = root.path
        let engine = try ClientEngine(settings: config)
        let error = StateDatabaseError(path: root.path, operation: "write", code: 8, detail: "injected")
        await engine.recordMaintenanceFailure(error)
        do {
            try await engine.checkMaintenance()
            Issue.record("Background persistence failure was hidden")
        } catch let observed as StateDatabaseError {
            #expect(observed.code == error.code)
        }
    }

    @Test func rejectsReadOnlyDatabaseAndJournalDirectoryAtStartup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("state-permissions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("client.sqlite")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            try? FileManager.default.removeItem(at: root)
        }
        func create() throws { try DurableStore(path: path.path).write(["saved": 7]) }
        try create()
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
        // Root bypasses POSIX permissions; normal CI and desktop users do not.
        if !FileManager.default.isWritableFile(atPath: path.path) {
            #expect(throws: StateDatabaseError.self) { try DurableStore(path: path.path) }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        if !FileManager.default.isWritableFile(atPath: root.path) {
            #expect(throws: StateDatabaseError.self) { try DurableStore(path: path.path) }
        }
    }

    @Test func duplicatePathNoticesAreSuppressed() async {
        let notices = PathAnnouncements()
        let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<20 { group.addTask { notices.claim("Metal slower; using CPU") } }
            var count = 0
            for await claimed in group where claimed { count += 1 }
            return count
        }
        #expect(count == 1)
        #expect(notices.claim("GPU failed; using CPU"))
    }
}
