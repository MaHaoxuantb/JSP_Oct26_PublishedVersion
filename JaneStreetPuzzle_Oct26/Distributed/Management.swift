import Foundation

enum ClientMode: String, Codable, Sendable { case running, paused, draining, quitting }
enum ManagementAction: String, Codable, Sendable { case pause, resume, drain, quit, workers, checkpoint }

/// Absolute desired state makes replay safe, including when an ACK is lost.
struct ClientDirective: Codable, Sendable {
    var id = UUID()
    var mode: ClientMode = .running
    var workerLimit: Int?
    var checkpoint = false
}
struct ControlAck: Codable, Sendable {
    var id: UUID
    var status: String
}
struct ManagementRequest: Codable, Sendable {
    var id: UUID
    var runID: UUID
    var clientID: UUID
    var action: ManagementAction
    var workers: Int?
}
struct ManagementCommand: Codable, Sendable {
    var request: ManagementRequest
    var createdAt: Double
    var status: String
}
struct WorkerTelemetry: Codable, Sendable {
    var slot: Int
    var state: String
    var backend: String
    var reason: String?
    var progressAt: Double? = nil
}
struct ClientTelemetry: Codable, Sendable {
    var sessionID: UUID
    var controlVersion: Int
    var capacity: Int
    var mode: ClientMode
    var capturedAt: Double
    var checkpointAt: Double?
    var workers: [WorkerTelemetry]
    var lastError: String?
}
struct FleetClient: Codable, Sendable {
    var telemetry: ClientTelemetry?
    var lastReportAt: Double
    var rate: Double
    var slotRates: [String: Double]? = nil
    var softwareVersion: Int? = nil
}
struct CandidateDiscovery: Codable, Sendable {
    var at: Double
    var clientID: UUID?
    var slot: Int?
    var objective: String?
}
struct QualityPoint: Codable, Sendable {
    var at: Double
    var issues: Int
    var wrong: Int
    var error: Double
    var candidateID: String
}
struct EnergyPoint: Codable, Sendable {
    var at: Double
    var total: Double
    var residual: Double
}
struct ThroughputPoint: Codable, Sendable {
    var at: Double
    var rate: Double
    var iterations: UInt64? = nil
    var activeWorkers: Int? = nil
}
struct DashboardEvent: Codable, Sendable {
    var at: Double
    var clientID: UUID?
    var message: String
}
struct SearchInsights: Codable, Sendable {
    var since = Date().timeIntervalSince1970
    var acceptedIterations: UInt64 = 0
    var discoveries: [String: CandidateDiscovery] = [:]
    var improvements: [QualityPoint] = []
    var energy: [EnergyPoint]? = nil
    var throughput: [ThroughputPoint] = []
    var events: [DashboardEvent] = []
}
struct DashboardCandidate: Codable, Sendable {
    var id: String
    var labels: [Int]
    var validation: ValidationReport
    var issues: Int
    var wrong: Int
    var error: Double
    var discovery: CandidateDiscovery?
}
