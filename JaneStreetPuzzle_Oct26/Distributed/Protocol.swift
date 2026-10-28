import Foundation
import Crypto


struct SearchJob: Codable, Sendable {
    var id: UUID = UUID()
    var generation: Int = 1
    var ordinal: UInt64 = 0
    var slot: Int
    var seed: UInt64
    var objective: SearchObjective
    var budget: Int
    var completed: Int = 0
    var owner: UUID
    var lastSeen: Double
    var progress: DistributedProgress?
    var explorer: Bool
}

struct JobReport: Codable, Sendable {
    var job: SearchJob
    var progress: DistributedProgress
    var release = false
}

struct WorkerRate: Codable, Sendable {
    var slot: Int
    var iterationsPerSecond: Double
    var repairSeconds: Double
}

struct ReplicaChunk: Codable, Sendable {
    var id: UUID
    var index: Int
    var count: Int
    var digest: String
    var bytes: Data
}

struct WireMessage: Codable, Sendable {
    static let version = 1
    static let maxFrame = 1_048_576
    var version = Self.version
    var kind: String
    var clientID: UUID?
    var machineName: String?
    var token: String?
    var runID: UUID?
    var config: RunConfig?
    var rates: [WorkerRate] = []
    var reports: [JobReport] = []
    var jobs: [SearchJob] = []
    var retired: [UUID] = []
    var elites: [[Int]] = []
    var solved = false
    var error: String?
    var replica: ReplicaChunk?
    var replicaAck: UUID?
    var replicaIndexAck: Int?
    var reconciling: Bool?
    var telemetry: ClientTelemetry?
    var control: ClientDirective?
    var controlAck: ControlAck?
}

struct CoordinatorStatus: Codable, Sendable {
    let runID: UUID
    let activeJobs: Int
    let completedJobs: UInt64
    let reassignments: UInt64
    let connectedClients: Int
    let solved: Bool
    let backupAgeSeconds: Double?
    let winner: [Int]?
}

struct CoordinatorState: Codable, Sendable {
    var runID = UUID()
    var config: RunConfig
    var serial: UInt64 = 0
    var joinToken: String?
    var recoveryFloor: UInt64?
    var reconciled: [UUID] = []
    var jobs: [SearchJob] = []
    // Optional for compatibility with existing coordinator databases and backups.
    var clientNames: [String: String]? = nil
    var elites: [[Int]] = []
    var solved = false
    var winner: [Int]?
    var completedJobs: UInt64 = 0
    var reassignments: UInt64 = 0
    var directives: [String: ClientDirective]? = nil
    var commands: [ManagementCommand]? = nil
    var fleet: [String: FleetClient]? = nil
    var insights: SearchInsights? = nil
}

enum DistributedError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let text): text } }
}

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func validLabels(_ labels: [Int], config: RunConfig) -> Bool {
    labels.count == config.rowNum * config.colNum && labels.allSatisfy { $0 >= 0 && $0 < labels.count }
}

func canonicalLabels(_ input: [Int]) -> [Int] {
    var mapping: [Int: Int] = [:]
    return input.map { label in
        if mapping[label] == nil { mapping[label] = mapping.count }
        return mapping[label]!
    }
}

func distributedLog(_ text: String) {
    try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
}
