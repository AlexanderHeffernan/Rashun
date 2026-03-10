// swift-tools-version: 6.2
import PackageDescription

var targets: [Target] = [
    .target(
        name: "RashunCore",
        path: "Sources/RashunCore"
    ),
    .executableTarget(
        name: "RashunCLI",
        dependencies: [
            "RashunCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ],
        path: "Sources/RashunCLI",
        exclude: [
            "PLAN.md"
        ]
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

#if os(macOS)
targets.append(
    .executableTarget(
        name: "Rashun",
        dependencies: ["RashunCore"],
        path: "Sources/RashunApp",
        exclude: [
            "README.md"
        ],
        resources: [
            .process("Resources")
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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: targets
)
#else
let package = Package(
    name: "Rashun",
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: targets
)
#endif
