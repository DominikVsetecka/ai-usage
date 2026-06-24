// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AIUsage",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AIUsage", targets: ["AIUsage"]),
        .executable(name: "AIUsageChecks", targets: ["AIUsageChecks"]),
        .executable(name: "AIUsageSnapshot", targets: ["AIUsageSnapshot"]),
        .library(name: "AIUsageCore", targets: ["AIUsageCore"])
    ],
    targets: [
        .target(
            name: "AIUsageCore"
        ),
        .executableTarget(
            name: "AIUsage",
            dependencies: ["AIUsageCore"]
        ),
        .executableTarget(
            name: "AIUsageChecks",
            dependencies: ["AIUsageCore"]
        ),
        .executableTarget(
            name: "AIUsageSnapshot",
            dependencies: ["AIUsageCore"]
        )
    ]
)
