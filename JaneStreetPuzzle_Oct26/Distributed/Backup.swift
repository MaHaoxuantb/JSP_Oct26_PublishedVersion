import Foundation
import Crypto

/// Confined to the coordinator queue. Snapshot construction is from the committed
/// state value, never a copy of a live SQLite database.
final class BackupService {
    private let key: SymmetricKey
    private let directory: URL
    private let settings: DistributedConfig
    private var created = -Double.infinity
    private var lastSent = -Double.infinity
    private var payload = Data()
    private var id = UUID()
    private var hash = ""
    private var offsets: [UUID: Int] = [:]
    private var completed: Set<UUID> = []
    private(set) var lastComplete: Double?
    private var contacts: [UUID: Double] = [:]
    private let chunkSize = 16_384

    init(directory: URL, settings: DistributedConfig) throws {
        self.directory = directory; self.settings = settings
        let path = directory.appendingPathComponent("recovery.key")
        if !FileManager.default.fileExists(atPath: path.path) {
            let fresh = SymmetricKey(size: .bits256)
            try writePrivate(fresh.withUnsafeBytes { Data($0) }, to: path)
        }
        let bytes = try Data(contentsOf: path)
        guard bytes.count == 32 else { throw DistributedError.message("Recovery key must contain 32 bytes.") }
        key = SymmetricKey(data: bytes)
    }
    func next(state: CoordinatorState, client: UUID, acknowledgment: UUID?, indexAck: Int?, now: Double) throws -> ReplicaChunk? {
        contacts = contacts.filter { now - $0.value <= settings.failureGraceSeconds }
        contacts[client] = now
        for owner in Array(offsets.keys) where now - contacts[owner, default: -1e100] > settings.failureGraceSeconds {
            offsets.removeValue(forKey: owner)
        }
        if acknowledgment == id, let indexAck, offsets[client] == indexAck {
            offsets[client] = indexAck + 1
            if (indexAck + 1) * chunkSize >= payload.count { completed.insert(client); lastComplete = now }
        }
        if now - created >= settings.backupSeconds && (payload.isEmpty || !completed.isEmpty) {
            payload = try Self.encrypt(state, key: key)
            id = UUID(); hash = digest(payload); offsets = [:]; completed = []; created = now
            try writePrivate(payload, to: directory.appendingPathComponent("latest-backup.encrypted"))
        }
        guard !payload.isEmpty, !completed.contains(client),
              offsets[client] != nil || offsets.count < 2,
              now - lastSent >= Double(chunkSize) / Double(settings.backupBytesPerSecond) else { return nil }
        let index = offsets[client, default: 0]
        offsets[client] = index
        lastSent = now
        let start = index * chunkSize
        guard start < payload.count else { return nil }
        return ReplicaChunk(id: id, index: index, count: (payload.count + chunkSize - 1) / chunkSize,
            digest: hash, bytes: payload.subdata(in: start..<min(payload.count, start + chunkSize)))
    }
    static func encrypt(_ state: CoordinatorState, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(JSONEncoder().encode(state), using: key).combined else {
            throw DistributedError.message("Cannot encrypt recovery snapshot.")
        }
        return combined
    }
    static func decrypt(_ data: Data, key: Data) throws -> CoordinatorState {
        guard key.count == 32 else { throw DistributedError.message("Invalid recovery key.") }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key))
        return try JSONDecoder().decode(CoordinatorState.self, from: plaintext)
    }
}

/// Chunk ACKs are sent only after a durable local write. A failed response can be
/// retried verbatim; completed replicas have an end-to-end ciphertext checksum.
struct ReplicaReceiver {
    let directory: URL
    mutating func accept(_ chunk: ReplicaChunk) throws {
        guard chunk.count > 0 && chunk.count <= 4096, chunk.index >= 0 && chunk.index < chunk.count,
              chunk.bytes.count <= 16_384, chunk.digest.count == 64 else { throw DistributedError.message("Invalid replica chunk.") }
        let finished = directory.appendingPathComponent("backup-\(chunk.id).encrypted")
        if let bytes = try? Data(contentsOf: finished), digest(bytes) == chunk.digest { return }
        let folder = directory.appendingPathComponent("replica-\(chunk.id)")
        if !FileManager.default.fileExists(atPath: folder.path) {
            for old in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where old.lastPathComponent.hasPrefix("replica-") && old != folder
                    && UUID(uuidString: String(old.lastPathComponent.dropFirst(8))) != nil {
                try FileManager.default.removeItem(at: old)
            }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writePrivate(chunk.bytes, to: folder.appendingPathComponent("\(chunk.index).chunk"))
        if chunk.index == chunk.count - 1 {
            var bytes = Data()
            for i in 0..<chunk.count { bytes.append(try Data(contentsOf: folder.appendingPathComponent("\(i).chunk"))) }
            guard digest(bytes) == chunk.digest else { throw DistributedError.message("Replica checksum mismatch.") }
            try writePrivate(bytes, to: directory.appendingPathComponent("backup-\(chunk.id).encrypted"))
            try FileManager.default.removeItem(at: folder)
            let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.lastPathComponent.hasPrefix("backup-") && $0.pathExtension == "encrypted" }
                .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            for old in backups.dropFirst(2) { try FileManager.default.removeItem(at: old) }
        }
    }
}
