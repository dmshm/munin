// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Munin",
    platforms: [.macOS(.v14)],
    targets: [
        // The save parsing and build logic, kept free of UI so it can be tested.
        .target(name: "MuninCore"),
        .executableTarget(
            name: "Munin",
            dependencies: ["MuninCore"],
            resources: [.copy("Resources/watchtower.json")]
        ),
        .testTarget(name: "MuninCoreTests", dependencies: ["MuninCore"]),
    ],
    swiftLanguageModes: [.v5]
)
