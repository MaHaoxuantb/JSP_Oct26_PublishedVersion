// swift-tools-version: 6.1
import PackageDescription
let package = Package(
  name: "JSP-Oct26-Repair-Completion", platforms: [.macOS(.v15)],
  products: [.executable(name: "completion-worker", targets: ["CompletionWorker"])],
  dependencies: [.package(path: "../solver_bench")],
  targets: [
    .target(name: "RepairPolicies", dependencies: [.product(name: "SolverCore", package: "solver_bench"), .product(name: "ShapeDomain", package: "solver_bench"), .product(name: "PuzzleRules", package: "solver_bench")]),
    .executableTarget(name: "CompletionWorker", dependencies: ["RepairPolicies"]),
    .testTarget(name: "RepairPolicyTests", dependencies: ["RepairPolicies"])
  ], swiftLanguageModes: [.v5])
