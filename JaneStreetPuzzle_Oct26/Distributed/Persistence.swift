import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
#if os(Linux)
import Glibc
import CoreFoundation
#else
import Darwin
#endif

enum StateDirectory {
    static func validate(_ directory: URL) throws {
        let components = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard !components.contains(where: {
            $0 == "Mobile Documents" || $0 == "CloudStorage" || $0 == "Dropbox"
                || $0 == "OneDrive" || $0.hasPrefix("OneDrive - ") || $0 == "Google Drive"
        }) else {
            throw DistributedError.message("State directory '\(directory.path)' is cloud-synced. Stop the process and migrate its state to a private local directory outside iCloud, Dropbox, OneDrive or Google Drive; see README.md. Live SQLite databases and process locks must not be synchronized.")
        }
    }
}

struct StateDatabaseError: Error, CustomStringConvertible {
    let path: String
    let operation: String
    let code: Int32
    let detail: String
    var pathChanged = false
    var description: String {
        var text = "State database '\(path)' (\(operation), SQLite \(code)): \(detail)."
        if pathChanged || code == (SQLITE_READONLY | (4 << 8)) {
            text += " The open database was moved or replaced. Stop the process and preserve its state before migrating to a private local directory; do not replace a live database."
        } else if code & 0xff == SQLITE_READONLY || code & 0xff == SQLITE_CANTOPEN {
            text += " Check database and parent-directory ownership, permissions and free space; use a private local state directory."
        }
        return text
    }
}

private struct StateFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    static func read(_ path: String) -> Self? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Self(device: info.st_dev, inode: info.st_ino)
    }
    func changed(at path: String) -> Bool {
        if let current = Self.read(path) { return current != self }
        return errno == ENOENT || errno == ENOTDIR
    }
}

/// A process holds its state directory exclusively. Never run two servers or
/// clients against the same directory, including while restoring a backup.
final class StateLock {
    private let fd: Int32
    init(directory: URL) throws {
        try StateDirectory.validate(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        fd = open(directory.appendingPathComponent("process.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw DistributedError.message("Cannot open state lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw DistributedError.message("State directory is already in use.")
        }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

/// Called only from its owning serial executor. SQLite commits precede network ACKs.
final class DurableStore {
    private var db: OpaquePointer?
    private let path: String
    private var fileIdentity: StateFileIdentity?
    init(path: String) throws {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        try StateDirectory.validate(URL(fileURLWithPath: self.path).deletingLastPathComponent())
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let error = failure(operation: "open")
            sqlite3_close(db); db = nil
            throw error
        }
        fileIdentity = StateFileIdentity.read(self.path)
        do {
            guard sqlite3_db_readonly(db, "main") == 0 else {
                throw StateDatabaseError(path: self.path, operation: "open for writing", code: SQLITE_READONLY,
                                         detail: "SQLite opened the state database read-only")
            }
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
            // Existing schemas can open successfully even if their directory cannot
            // create a journal. Verify the actual write path before accepting work.
            try execute("BEGIN IMMEDIATE")
            try execute("INSERT OR REPLACE INTO state(key,value) VALUES('__startup_write_probe__', X'00')")
            try execute("ROLLBACK")
        } catch { sqlite3_close(db); db = nil; throw error }
        _ = chmod(path, 0o600)
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure(operation: sql) }
    }
    private func failure(operation: String) -> StateDatabaseError {
        StateDatabaseError(path: path, operation: operation, code: sqlite3_extended_errcode(db),
                           detail: String(cString: sqlite3_errmsg(db)), pathChanged: fileIdentity?.changed(at: path) ?? false)
    }
    func read<T: Decodable>(_ type: T.Type, key: String = "state") throws -> T? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM state WHERE key=?", -1, &statement, nil) == SQLITE_OK else { throw failure(operation: "prepare read") }
        defer { sqlite3_finalize(statement) }
        guard key.withCString({ sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }) == SQLITE_OK else { throw failure(operation: "bind read") }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let blob = sqlite3_column_blob(statement, 0) else { throw failure(operation: "read") }
        return try JSONDecoder().decode(type, from: Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0))))
    }
    func write<T: Encodable>(_ value: T, key: String = "state") throws {
        let data = try JSONEncoder().encode(value)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO state(key,value) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK else { throw failure(operation: "prepare write") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard key.withCString({ sqlite3_bind_text(statement, 1, $0, -1, transient) }) == SQLITE_OK,
              data.withUnsafeBytes({ sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw failure(operation: "write") }
    }
}

func writePrivate(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-\(UUID())")
    let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard descriptor >= 0 else { throw DistributedError.message("Cannot create private state file.") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw DistributedError.message("Cannot replace state file.") }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard parent >= 0 else { throw DistributedError.message("Cannot open state directory for synchronization.") }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw DistributedError.message("Cannot synchronize state directory.") }
    } catch {
        try? handle.close()
        _ = unlink(temporary.path)
        throw error
    }
}
