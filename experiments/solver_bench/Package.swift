// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "PuzzleBench", platforms: [.macOS(.v15)],
  products: [
    .library(name: "PuzzleRules", targets: ["PuzzleRules"]),
    .library(name: "ShapeDomain", targets: ["ShapeDomain"]),
    .library(name: "SolverCore", targets: ["SolverCore"]),
    .library(name: "BoardPreparation", targets: ["BoardPreparation"]),
    .executable(name: "bench-worker", targets: ["BenchWorker"]),
    .executable(name: "bench-tools", targets: ["BenchTools"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .target(name: "PuzzleRules"),
    .target(name: "ShapeDomain", dependencies: ["PuzzleRules", "CSQLite"]),
    .target(name: "SolverCore", dependencies: ["PuzzleRules", "ShapeDomain"]),
    .target(name: "BoardPreparation", dependencies: ["PuzzleRules", "ShapeDomain"]),
    .executableTarget(name: "BenchWorker", dependencies: ["SolverCore"]),
    .executableTarget(name: "BenchTools", dependencies: ["BoardPreparation", "SolverCore"]),
    .testTarget(
      name: "BenchTests",
      dependencies: ["PuzzleRules", "ShapeDomain", "SolverCore", "BoardPreparation"]),
  ], swiftLanguageModes: [.v5])
