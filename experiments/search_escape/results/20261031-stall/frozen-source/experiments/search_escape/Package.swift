// swift-tools-version: 6.1
import PackageDescription
let package = Package(name:"JSP-Oct26-Search-Escape",platforms:[.macOS(.v15)],
 products:[.library(name:"EscapePolicies",targets:["EscapePolicies"]),.executable(name:"escape-worker",targets:["EscapeWorker"])],
 dependencies:[.package(path:"../repair_completion"),.package(path:"../solver_bench")],
 targets:[.target(name:"EscapePolicies",dependencies:[.product(name:"RepairPolicies",package:"repair_completion"),.product(name:"SolverCore",package:"solver_bench"),.product(name:"ShapeDomain",package:"solver_bench"),.product(name:"PuzzleRules",package:"solver_bench")]),
 .executableTarget(name:"EscapeWorker",dependencies:["EscapePolicies"]),.testTarget(name:"EscapeTests",dependencies:["EscapePolicies"])],swiftLanguageModes:[.v5])
