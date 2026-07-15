// swift-tools-version: 6.2
import PackageDescription

var targets: [Target] = [
    .target(
        name: "RashunCore",
        path: "Sources/RashunCore"
    ),
    .target(
        name: "RashunSync",
        dependencies: [
            "RashunCore",
            .product(name: "Crypto", package: "swift-crypto"),
        ],
        path: "Sources/RashunSync"
    ),
    .target(
        name: "RashunSyncServer",
        dependencies: [
            "RashunSync", .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdTLS", package: "hummingbird"),
        ],
        path: "Sources/RashunSyncServer"
    ),
    .executableTarget(
        name: "RashunCLI",
        dependencies: [
            "RashunCore", "RashunSync", "RashunSyncServer",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        path: "Sources/RashunCLI"
    ),
    .testTarget(
        name: "RashunCoreTests",
        dependencies: ["RashunCore"],
        path: "Tests/RashunCoreTests"
    ),
    .testTarget(
        name: "RashunCLITests",
        dependencies: ["RashunCLI"],
        path: "Tests/RashunCLITests"
    ),
    .testTarget(
        name: "RashunSyncTests",
        dependencies: [
            "RashunSync", "RashunSyncServer",
            .product(name: "HummingbirdTesting", package: "hummingbird"),
        ],
        path: "Tests/RashunSyncTests"
    ),
]

#if os(macOS)
    targets.append(
        .executableTarget(
            name: "Rashun",
            dependencies: ["RashunCore", "RashunSync", "RashunSyncServer"],
            path: "Sources/RashunApp",
            exclude: [
                "README.md"
            ],
            resources: [
                .process("Resources"),
                .copy("../../Web/RashunMobile"),
            ]
        )
    )
    targets.append(
        .testTarget(
            name: "RashunAppTests",
            dependencies: ["Rashun"],
            path: "Tests/RashunAppTests"
        )
    )
#endif

#if os(macOS)
    let package = Package(
        name: "Rashun",
        platforms: [.macOS(.v14)],
        dependencies: [
            .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
            .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
            .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        ],
        targets: targets
    )
#else
    let package = Package(
        name: "Rashun",
        dependencies: [
            .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
            .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
            .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        ],
        targets: targets
    )
#endif
