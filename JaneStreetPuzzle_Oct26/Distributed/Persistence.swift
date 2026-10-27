import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// A process holds its state directory exclusively. Never run two servers or
/// clients against the same directory, including while restoring a backup.
final class StateLock {
    private let fd: Int32
    init(directory: URL) throws {
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
    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            sqlite3_close(db); db = nil
            throw DistributedError.message("Cannot open state database.")
        }
        do {
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
        } catch { sqlite3_close(db); db = nil; throw error }
        _ = chmod(path, 0o600)
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> DistributedError { .message("State database: \(String(cString: sqlite3_errmsg(db)))") }
    func read<T: Decodable>(_ type: T.Type, key: String = "state") throws -> T? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM state WHERE key=?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard key.withCString({ sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }) == SQLITE_OK else { throw failure() }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let blob = sqlite3_column_blob(statement, 0) else { throw failure() }
        return try JSONDecoder().decode(type, from: Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0))))
    }
    func write<T: Encodable>(_ value: T, key: String = "state") throws {
        let data = try JSONEncoder().encode(value)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO state(key,value) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard key.withCString({ sqlite3_bind_text(statement, 1, $0, -1, transient) }) == SQLITE_OK,
              data.withUnsafeBytes({ sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
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
