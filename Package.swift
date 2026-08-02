// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "K811Mac",
    defaultLocalization: "ko",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "K811Core", targets: ["K811Core"]),
        .executable(name: "k811-probe", targets: ["K811Probe"]),
        .executable(name: "k811-dump", targets: ["K811Dump"]),
        .executable(name: "k811-agent-event", targets: ["K811AgentEvent"]),
        .executable(name: "K811Mac", targets: ["K811Mac"]),
    ],
    targets: [
        .target(
            name: "K811Core",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "K811Probe",
            dependencies: ["K811Core"]
        ),
        .executableTarget(
            name: "K811Dump",
            dependencies: ["K811Core"]
        ),
        .executableTarget(
            name: "K811AgentEvent",
            dependencies: ["K811Core"]
        ),
        .executableTarget(
            name: "K811Mac",
            dependencies: ["K811Core"]
        ),
        .testTarget(
            name: "K811CoreTests",
            dependencies: ["K811Core"]
        ),
    ]
)
