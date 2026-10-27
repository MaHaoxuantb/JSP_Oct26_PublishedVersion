import Foundation

struct RunConfig: Codable, Sendable {
    var distributed = DistributedConfig()
    var workerCount = 10
    // Each iteration is now a bounded repair job, not a single edge proposal.
    var maxMergeRegions = 4
    var mergeCandidateLimit = 1_000
    var repairTimeLimitSeconds: Double = 0.15
    var maxPatchCells = 32
    var largePatchCells = 128
    var largeRepairInterval = 12
    var boundaryCandidateLimit = 96
    var useRouteBounds = true
    var checkpointIntervalSeconds: Double = 60
    // Runtime worker objective; exact validation and final ranking stay common.
    var searchObjective: SearchObjective = .matches
    var catalogCandidateLimit = 12_000
    var catalogMasksPerTransform = 256
    var exactCoverNodeLimit = 5_000
    var exactCoverSolutionLimit = 48
    var eliteCapacity = 8
    var exchangeInterval = 20
    var exchangeTimeIntervalSeconds: Double = 1
    var rowNum = 5
    var colNum = 5
    var Target = OriginalCondition(Status: [
        [12, -1, -1, -1, 17],
        [8, -1, 6, 3, -1],
        [-1, -1, -1, -1, -1],
        [-1, 7, 6, -1, 10],
        [25, -1, -1, -1, 0]
    ])
    var seed: UInt64 = 20261026
    var factors = Energy.Factors(realAIM: 2, symmetry: 1, discreteness: 0.25)
    var maxIterations = 100_000_000
    var timeLimitSeconds: Double = 1_000_000
    var initialTemperature: Double = 0.03
    var minimumTemperature: Double = 0.0001
    var coolingRate: Double = 0.997
    var stagnationIterations = 100
    var reheatsPerRestart = 1
    var maxRestarts = 20_000
    var uniformSelectionProbability: Double = 0.2
    var progressInterval = 10
    var progressTimeIntervalSeconds: Double = 2
    var yieldInterval = 25
    // Xcode supplies absolute source paths. CLI builds should also pass absolute
    // source paths so this remains anchored to the project when launched elsewhere.
    var logDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("logs", isDirectory: true).path
    var consoleLogging = true

    init() {}
    private enum CodingKeys: String, CodingKey {
        case distributed, workerCount, maxMergeRegions, mergeCandidateLimit, repairTimeLimitSeconds, maxPatchCells, largePatchCells, largeRepairInterval, boundaryCandidateLimit, useRouteBounds, checkpointIntervalSeconds, searchObjective, catalogCandidateLimit, catalogMasksPerTransform, exactCoverNodeLimit, exactCoverSolutionLimit, eliteCapacity, exchangeInterval, exchangeTimeIntervalSeconds, rowNum, colNum, Target, seed, factors, maxIterations, timeLimitSeconds, initialTemperature, minimumTemperature, coolingRate, stagnationIterations, reheatsPerRestart, maxRestarts, uniformSelectionProbability, progressInterval, progressTimeIntervalSeconds, yieldInterval, logDirectory, consoleLogging
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.distributed) { distributed = try values.decode(type(of: distributed), forKey: .distributed) }
        if values.contains(.workerCount) { workerCount = try values.decode(type(of: workerCount), forKey: .workerCount) }
        if values.contains(.maxMergeRegions) { maxMergeRegions = try values.decode(type(of: maxMergeRegions), forKey: .maxMergeRegions) }
        if values.contains(.mergeCandidateLimit) { mergeCandidateLimit = try values.decode(type(of: mergeCandidateLimit), forKey: .mergeCandidateLimit) }
        if values.contains(.repairTimeLimitSeconds) { repairTimeLimitSeconds = try values.decode(type(of: repairTimeLimitSeconds), forKey: .repairTimeLimitSeconds) }
        if values.contains(.maxPatchCells) { maxPatchCells = try values.decode(type(of: maxPatchCells), forKey: .maxPatchCells) }
        if values.contains(.largePatchCells) { largePatchCells = try values.decode(type(of: largePatchCells), forKey: .largePatchCells) }
        if values.contains(.largeRepairInterval) { largeRepairInterval = try values.decode(type(of: largeRepairInterval), forKey: .largeRepairInterval) }
        if values.contains(.boundaryCandidateLimit) { boundaryCandidateLimit = try values.decode(type(of: boundaryCandidateLimit), forKey: .boundaryCandidateLimit) }
        if values.contains(.useRouteBounds) { useRouteBounds = try values.decode(type(of: useRouteBounds), forKey: .useRouteBounds) }
        if values.contains(.checkpointIntervalSeconds) { checkpointIntervalSeconds = try values.decode(type(of: checkpointIntervalSeconds), forKey: .checkpointIntervalSeconds) }
        if values.contains(.searchObjective) { searchObjective = try values.decode(type(of: searchObjective), forKey: .searchObjective) }
        if values.contains(.catalogCandidateLimit) { catalogCandidateLimit = try values.decode(type(of: catalogCandidateLimit), forKey: .catalogCandidateLimit) }
        if values.contains(.catalogMasksPerTransform) { catalogMasksPerTransform = try values.decode(type(of: catalogMasksPerTransform), forKey: .catalogMasksPerTransform) }
        if values.contains(.exactCoverNodeLimit) { exactCoverNodeLimit = try values.decode(type(of: exactCoverNodeLimit), forKey: .exactCoverNodeLimit) }
        if values.contains(.exactCoverSolutionLimit) { exactCoverSolutionLimit = try values.decode(type(of: exactCoverSolutionLimit), forKey: .exactCoverSolutionLimit) }
        if values.contains(.eliteCapacity) { eliteCapacity = try values.decode(type(of: eliteCapacity), forKey: .eliteCapacity) }
        if values.contains(.exchangeInterval) { exchangeInterval = try values.decode(type(of: exchangeInterval), forKey: .exchangeInterval) }
        if values.contains(.exchangeTimeIntervalSeconds) { exchangeTimeIntervalSeconds = try values.decode(type(of: exchangeTimeIntervalSeconds), forKey: .exchangeTimeIntervalSeconds) }
        if values.contains(.rowNum) { rowNum = try values.decode(type(of: rowNum), forKey: .rowNum) }
        if values.contains(.colNum) { colNum = try values.decode(type(of: colNum), forKey: .colNum) }
        if values.contains(.Target) { Target = try values.decode(type(of: Target), forKey: .Target) }
        if values.contains(.seed) { seed = try values.decode(type(of: seed), forKey: .seed) }
        if values.contains(.factors) { factors = try values.decode(type(of: factors), forKey: .factors) }
        if values.contains(.maxIterations) { maxIterations = try values.decode(type(of: maxIterations), forKey: .maxIterations) }
        if values.contains(.timeLimitSeconds) { timeLimitSeconds = try values.decode(type(of: timeLimitSeconds), forKey: .timeLimitSeconds) }
        if values.contains(.initialTemperature) { initialTemperature = try values.decode(type(of: initialTemperature), forKey: .initialTemperature) }
        if values.contains(.minimumTemperature) { minimumTemperature = try values.decode(type(of: minimumTemperature), forKey: .minimumTemperature) }
        if values.contains(.coolingRate) { coolingRate = try values.decode(type(of: coolingRate), forKey: .coolingRate) }
        if values.contains(.stagnationIterations) { stagnationIterations = try values.decode(type(of: stagnationIterations), forKey: .stagnationIterations) }
        if values.contains(.reheatsPerRestart) { reheatsPerRestart = try values.decode(type(of: reheatsPerRestart), forKey: .reheatsPerRestart) }
        if values.contains(.maxRestarts) { maxRestarts = try values.decode(type(of: maxRestarts), forKey: .maxRestarts) }
        if values.contains(.uniformSelectionProbability) { uniformSelectionProbability = try values.decode(type(of: uniformSelectionProbability), forKey: .uniformSelectionProbability) }
        if values.contains(.progressInterval) { progressInterval = try values.decode(type(of: progressInterval), forKey: .progressInterval) }
        if values.contains(.progressTimeIntervalSeconds) { progressTimeIntervalSeconds = try values.decode(type(of: progressTimeIntervalSeconds), forKey: .progressTimeIntervalSeconds) }
        if values.contains(.yieldInterval) { yieldInterval = try values.decode(type(of: yieldInterval), forKey: .yieldInterval) }
        if values.contains(.logDirectory) { logDirectory = try values.decode(type(of: logDirectory), forKey: .logDirectory) }
        if values.contains(.consoleLogging) { consoleLogging = try values.decode(type(of: consoleLogging), forKey: .consoleLogging) }
    }

    static var example: RunConfig { RunConfig() }

    /// Preserve the transcribed 11×11 puzzle without making it the default run.
    static var fullPuzzle: RunConfig {
        var config = RunConfig()
        config.rowNum = 11
        config.colNum = 11
        config.Target = OriginalCondition(Status: [
            [-1,  8,  4, -1, -1, 11, -1, -1, -1,  5, -1],
            [-1, -1, -1, -1, -1, -1, -1, 11, -1, -1, -1],
            [-1, -1,  7, -1, -1,  1, -1, -1, -1, -1, 14],
            [28, -1, -1, 51, -1, -1,  1, -1,  6, -1, -1],
            [-1, 22, -1, -1, -1, -1, -1, -1,  4, -1,  1],
            [-1, -1, -1, 15, -1, 10, -1,  0, -1, -1, -1],
            [11, -1, 11, -1, -1, -1, -1, -1, -1,  9, -1],
            [-1, -1, 17, -1, 14, -1, -1, 10, -1, -1, 13],
            [30, -1, -1, -1, -1,  6, -1, -1, 45, -1, -1],
            [-1, -1, -1, 10, -1, -1, -1, -1, -1, -1, -1],
            [-1, 26, -1, -1, -1,  0, -1, -1, 77, 61, -1]
        ])
        return config
    }

    func validate() throws {
        func require(_ valid: Bool, _ message: String) throws {
            if !valid { throw ConfigurationError(message: message) }
        }
        try require(workerCount > 0, "Worker count must be positive.")
        try require((2...4).contains(maxMergeRegions) && mergeCandidateLimit > 0,
                    "Merge repairs must cover two to four regions with a positive budget.")
        try require(maxPatchCells > 0 && largePatchCells >= maxPatchCells && catalogCandidateLimit > 0
                    && catalogMasksPerTransform > 0 && exactCoverNodeLimit > 0 && exactCoverSolutionLimit > 0,
                    "Invalid region-catalog or exact-cover limits.")
        try require(largeRepairInterval > 0 && boundaryCandidateLimit > 0
                    && checkpointIntervalSeconds.isFinite && checkpointIntervalSeconds > 0,
                    "Invalid large-repair or checkpoint limits.")
        try require(repairTimeLimitSeconds.isFinite && repairTimeLimitSeconds > 0,
                    "Repair time limit must be positive and finite.")
        try require(eliteCapacity > 0 && exchangeInterval > 0
                    && exchangeTimeIntervalSeconds.isFinite && exchangeTimeIntervalSeconds > 0,
                    "Invalid elite archive or exchange interval.")
        try require(rowNum > 0 && colNum > 0 && !rowNum.multipliedReportingOverflow(by: colNum).overflow,
                    "Board dimensions must be positive and their product must fit in Int.")
        try require(Target.Status.count == rowNum && Target.Status.allSatisfy { $0.count == colNum },
                    "Target dimensions must match the board.")
        try require(Target.Status.joined().allSatisfy { $0 >= -1 }
                    && Target.Status.joined().contains { $0 >= 0 }, "Provide at least one clue; use -1 for blanks.")
        try require([factors.realAIM, factors.symmetry, factors.discreteness].allSatisfy { $0.isFinite && $0 > 0 },
                    "The solver requires three positive finite factors.")
        try require(maxIterations > 0 && timeLimitSeconds.isFinite && timeLimitSeconds > 0,
                    "Iteration and time limits must be positive.")
        try require(initialTemperature.isFinite && minimumTemperature.isFinite && minimumTemperature > 0
                    && initialTemperature >= minimumTemperature, "Invalid annealing temperatures.")
        try require(coolingRate.isFinite && coolingRate > 0 && coolingRate <= 1, "Cooling rate must be in (0, 1].")
        try require(stagnationIterations > 0 && reheatsPerRestart >= 0 && maxRestarts >= 0,
                    "Invalid stagnation/restart limits.")
        try require(progressInterval > 0 && yieldInterval > 0, "Intervals must be positive.")
        try require(progressTimeIntervalSeconds.isFinite && progressTimeIntervalSeconds >= 0,
                    "Progress time interval must be finite and nonnegative.")
        try require(uniformSelectionProbability.isFinite && (0...1).contains(uniformSelectionProbability),
                    "Uniform selection probability must be in [0, 1].")
        try require(!logDirectory.isEmpty, "Provide a log directory.")
    }
}

struct ConfigurationError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Network addresses are numeric literals, never URLs. Secrets live in separate files.
struct DistributedConfig: Codable, Sendable {
    var address = "127.0.0.1"
    var port = 8443
    var webUIEnabled = true
    var webUIAddress = "127.0.0.1"
    var webUIPort = 8080
    var stateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/janestreet-puzzle").path
    var certificatePath = ""
    var tokenPath = ""
    var clientWorkers: Int? = nil
    var maxClients = 20
    var maxWorkersPerClient = 128
    var heartbeatSeconds = 15.0
    var checkpointSeconds = 30.0
    var failureGraceSeconds = 180.0
    var jobSeconds = 120.0
    var calibrationSeconds = 5.0
    var backupsEnabled = false
    var backupSeconds = 300.0
    var backupBytesPerSecond = 65_536

    init() {}
    private enum CodingKeys: String, CodingKey { case address, port, webUIEnabled, webUIAddress, webUIPort, stateDirectory, certificatePath, tokenPath, clientWorkers, maxClients, maxWorkersPerClient, heartbeatSeconds, checkpointSeconds, failureGraceSeconds, jobSeconds, calibrationSeconds, backupsEnabled, backupSeconds, backupBytesPerSecond }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.address) { address = try values.decode(type(of: address), forKey: .address) }
        if values.contains(.port) { port = try values.decode(type(of: port), forKey: .port) }
        if values.contains(.webUIEnabled) { webUIEnabled = try values.decode(type(of: webUIEnabled), forKey: .webUIEnabled) }
        if values.contains(.webUIAddress) { webUIAddress = try values.decode(type(of: webUIAddress), forKey: .webUIAddress) }
        if values.contains(.webUIPort) { webUIPort = try values.decode(type(of: webUIPort), forKey: .webUIPort) }
        if values.contains(.stateDirectory) { stateDirectory = try values.decode(type(of: stateDirectory), forKey: .stateDirectory) }
        if values.contains(.certificatePath) { certificatePath = try values.decode(type(of: certificatePath), forKey: .certificatePath) }
        if values.contains(.tokenPath) { tokenPath = try values.decode(type(of: tokenPath), forKey: .tokenPath) }
        if values.contains(.clientWorkers) { clientWorkers = try values.decode(type(of: clientWorkers), forKey: .clientWorkers) }
        if values.contains(.maxClients) { maxClients = try values.decode(type(of: maxClients), forKey: .maxClients) }
        if values.contains(.maxWorkersPerClient) { maxWorkersPerClient = try values.decode(type(of: maxWorkersPerClient), forKey: .maxWorkersPerClient) }
        if values.contains(.heartbeatSeconds) { heartbeatSeconds = try values.decode(type(of: heartbeatSeconds), forKey: .heartbeatSeconds) }
        if values.contains(.checkpointSeconds) { checkpointSeconds = try values.decode(type(of: checkpointSeconds), forKey: .checkpointSeconds) }
        if values.contains(.failureGraceSeconds) { failureGraceSeconds = try values.decode(type(of: failureGraceSeconds), forKey: .failureGraceSeconds) }
        if values.contains(.jobSeconds) { jobSeconds = try values.decode(type(of: jobSeconds), forKey: .jobSeconds) }
        if values.contains(.calibrationSeconds) { calibrationSeconds = try values.decode(type(of: calibrationSeconds), forKey: .calibrationSeconds) }
        if values.contains(.backupsEnabled) { backupsEnabled = try values.decode(type(of: backupsEnabled), forKey: .backupsEnabled) }
        if values.contains(.backupSeconds) { backupSeconds = try values.decode(type(of: backupSeconds), forKey: .backupSeconds) }
        if values.contains(.backupBytesPerSecond) { backupBytesPerSecond = try values.decode(type(of: backupBytesPerSecond), forKey: .backupBytesPerSecond) }
    }

    var workers: Int { clientWorkers ?? min(maxWorkersPerClient, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)) }
    func validate() throws {
        guard !webUIEnabled || ((1...65535).contains(webUIPort) && webUIPort != port && !webUIAddress.isEmpty) else {
            throw ConfigurationError(message: "WebUI needs a numeric bind address and a port from 1–65535 different from the coordinator port.")
        }
        guard (1...65535).contains(port), !stateDirectory.isEmpty,
              maxClients > 0, maxClients <= 1000, maxWorkersPerClient > 0, maxWorkersPerClient <= 128,
              workers > 0, workers <= maxWorkersPerClient,
              [heartbeatSeconds, checkpointSeconds, failureGraceSeconds, jobSeconds, calibrationSeconds, backupSeconds]
                .allSatisfy({ $0.isFinite && $0 > 0 }),
              failureGraceSeconds >= heartbeatSeconds * 3, backupBytesPerSecond > 0 else {
            throw ConfigurationError(message: "Invalid distributed settings or client worker count.")
        }
    }
}

struct DistributedProgress: Codable, Sendable {
    var current: [Int]
    var best: [Int]
    var iterations: Int
    var seconds: Double
    var finished: Bool
    var solved: Bool
}
