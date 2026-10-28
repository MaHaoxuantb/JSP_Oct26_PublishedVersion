// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "JaneStreetPuzzle",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "janestreet-puzzle", targets: ["PuzzleSolver"])],
    dependencies: [
        // NIO's unconstrained transitive update selected Collections 1.7.5,
        // which requires Swift 6.4. Keep builds usable on our Swift 6.1 hosts.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.1")
    ],
    targets: [
        // Loads CUDA at runtime; CPU builds need no CUDA SDK.
        .target(name: "CUDAPaths", path: "Sources/CUDAPaths",
                linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
        .executableTarget(name: "PuzzleSolver", dependencies: [
            .target(name: "CUDAPaths", condition: .when(platforms: [.linux])),
            "CSQLite", .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
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
