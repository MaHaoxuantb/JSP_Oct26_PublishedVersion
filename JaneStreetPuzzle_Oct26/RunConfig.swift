import Foundation

struct RunConfig: Codable, Sendable {
    var workerCount = 10
    // Each iteration is now a bounded repair job, not a single edge proposal.
    var maxMergeRegions = 4
    var mergeCandidateLimit = 1_000
    var repairTimeLimitSeconds: Double = 0.15
    var maxPatchCells = 32
    var catalogCandidateLimit = 12_000
    var catalogMasksPerTransform = 256
    var exactCoverNodeLimit = 5_000
    var exactCoverSolutionLimit = 48
    var eliteCapacity = 8
    var exchangeInterval = 20
    var exchangeTimeIntervalSeconds: Double = 1
    var rowNum = 11
    var colNum = 11
    // Transcribed row by row from the supplied puzzle. -1 denotes a blank;
    // zero is a clue and must not be replaced by -1.
    var Target = OriginalCondition(Status: [
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
    var seed: UInt64 = 20261026
    var factors = Energy.Factors(realAIM: 2, symmetry: 1, discreteness: 0.25)
    var maxIterations = 500_000
    var timeLimitSeconds: Double = 1_000
    var initialTemperature: Double = 0.03
    var minimumTemperature: Double = 0.0001
    var coolingRate: Double = 0.997
    var stagnationIterations = 100
    var reheatsPerRestart = 1
    var maxRestarts = 20
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

    /// Keep the illustrated example independent of the default puzzle so
    /// regression checks and the example benchmark retain their original input.
    static var example: RunConfig {
        var config = RunConfig()
        config.rowNum = 5
        config.colNum = 5
        config.Target = OriginalCondition(Status: [
            [12, -1, -1, -1, 17],
            [8, -1, 6, 3, -1],
            [-1, -1, -1, -1, -1],
            [-1, 7, 6, -1, 10],
            [25, -1, -1, -1, 0]
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
        try require((1...63).contains(maxPatchCells) && catalogCandidateLimit > 0
                    && catalogMasksPerTransform > 0 && exactCoverNodeLimit > 0 && exactCoverSolutionLimit > 0,
                    "Invalid region-catalog or exact-cover limits; patches support up to 63 cells.")
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
