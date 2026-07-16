// swift-tools-version: 6.2
import PackageDescription

var cliDependencies: [Target.Dependency] = [
    "RashunCore", "RashunSync",
    .product(name: "ArgumentParser", package: "swift-argument-parser"),
]

#if !os(Windows)
    cliDependencies.append("RashunSyncServer")
#endif

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
    .executableTarget(
        name: "RashunCLI",
        dependencies: cliDependencies,
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
]

#if !os(Windows)
    // Hummingbird does not support Windows. Keep the client-side sync commands
    // available there, but only compile the server on supported platforms.
    targets.append(
        .target(
            name: "RashunSyncServer",
            dependencies: [
                "RashunSync",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
            ],
            path: "Sources/RashunSyncServer"
        )
    )
    // HummingbirdTesting currently pulls in CNIOExtrasZlib, whose generated
    // configuration includes the POSIX-only unistd.h on Windows.
    targets.append(
        .testTarget(
            name: "RashunSyncTests",
            dependencies: [
                "RashunSync", "RashunSyncServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/RashunSyncTests"
        )
    )
#endif

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
            // Temporary Windows compatibility override until swift-nio-extras#294 is released.
            .package(
                url: "https://github.com/apple/swift-nio-extras.git",
                revision: "076c9b493c6fe365ba42663fc16c4239d17dfb92"
            ),
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
            // Temporary Windows compatibility override until swift-nio-extras#294 is released.
            .package(
                url: "https://github.com/apple/swift-nio-extras.git",
                revision: "076c9b493c6fe365ba42663fc16c4239d17dfb92"
            ),
        ],
        targets: targets
    )
#endif
