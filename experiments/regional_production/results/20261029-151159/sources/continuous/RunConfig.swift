import Foundation

struct RunConfig: Codable, Sendable {
    var workerCount = 10
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
    var maxIterations = 500_000
    var timeLimitSeconds: Double = 1_000
    var initialTemperature: Double = 0.03
    var minimumTemperature: Double = 0.0001
    var coolingRate: Double = 0.997
    var stagnationIterations = 1_000
    var reheatsPerRestart = 1
    var maxRestarts = 20
    var minimumInitialRegions = 2
    var maximumInitialRegions = 12
    var proposalAttempts = 8
    var uniformSelectionProbability: Double = 0.2
    var progressInterval = 100
    var progressTimeIntervalSeconds: Double = 2
    var yieldInterval = 25
    // Xcode supplies absolute source paths. CLI builds should also pass absolute
    // source paths so this remains anchored to the project when launched elsewhere.
    var logDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("logs", isDirectory: true).path
    var consoleLogging = true

    func validate() throws {
        func require(_ valid: Bool, _ message: String) throws {
            if !valid { throw ConfigurationError(message: message) }
        }
        try require(workerCount > 0, "Worker count must be positive.")
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
        try require(minimumInitialRegions > 0 && maximumInitialRegions >= minimumInitialRegions,
                    "Invalid initial region range.")
        try require(proposalAttempts > 0 && progressInterval > 0 && yieldInterval > 0, "Intervals must be positive.")
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
