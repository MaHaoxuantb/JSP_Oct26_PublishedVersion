// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "JaneStreetPuzzle",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "janestreet-puzzle", targets: ["PuzzleSolver"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.1")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
        .executableTarget(name: "PuzzleSolver", dependencies: [
            "CSQLite", .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "SwiftASN1", package: "swift-asn1")
        ], path: "JaneStreetPuzzle_Oct26", swiftSettings: [
            .enableUpcomingFeature("MemberImportVisibility")
        ]),
        .testTarget(name: "DistributedTests", dependencies: ["PuzzleSolver",
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOPosix", package: "swift-nio")
        ], path: "DistributedTests")
    ],
    swiftLanguageModes: [.v6]
)
