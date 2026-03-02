// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Rashun",
    platforms: [
        .macOS(.v11)  // Or .v12, .v13, .v14, .v15 depending on your needs
                      // .v11 is safe and enables async/await + @MainActor without issues
    ],
    targets: [
        .executableTarget(
            name: "Rashun",
            path: "Sources"
        ),
        .testTarget(
            name: "RashunTests",
            dependencies: ["Rashun"],
            path: "Tests"
        ),
    ]
)