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
    targets: targets
)
#else
let package = Package(
    name: "Rashun",
    targets: targets
)
#endif
