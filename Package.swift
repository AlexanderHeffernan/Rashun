// swift-tools-version: 6.2
import PackageDescription

var targets: [Target] = [
    .target(
        name: "RashunCore",
        path: "Sources/RashunCore"
    ),
    .executableTarget(
        name: "RashunCLI",
        dependencies: ["RashunCore"],
        path: "Sources/RashunCLI"
    ),
    .testTarget(
        name: "RashunCoreTests",
        dependencies: ["RashunCore"],
        path: "Tests/RashunCoreTests"
    ),
]

var platforms: [SupportedPlatform] = []

#if os(macOS)
platforms = [.macOS(.v14)]
targets.append(
    .executableTarget(
        name: "Rashun",
        dependencies: ["RashunCore"],
        path: "Sources/RashunApp",
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

let package = Package(
    name: "Rashun",
    platforms: platforms,
    targets: targets
)
