// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ProjectMemory",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ProjectMemoryApp",
            targets: ["ProjectMemoryApp"]
        ),
        .library(
            name: "ProjectMemoryCore",
            targets: ["ProjectMemoryCore"]
        ),
        .library(
            name: "ProjectMemoryEvalSupport",
            targets: ["ProjectMemoryEvalSupport"]
        ),
        .executable(
            name: "ProjectMemoryEval",
            targets: ["ProjectMemoryEval"]
        )
    ],
    targets: [
        .target(
            name: "ProjectMemoryCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "ProjectMemoryApp",
            dependencies: ["ProjectMemoryCore"]
        ),
        .target(
            name: "ProjectMemoryEvalSupport",
            dependencies: ["ProjectMemoryCore"]
        ),
        .executableTarget(
            name: "ProjectMemoryEval",
            dependencies: ["ProjectMemoryEvalSupport"]
        ),
        .testTarget(
            name: "ProjectMemoryCoreTests",
            dependencies: [
                "ProjectMemoryCore",
                "ProjectMemoryEvalSupport"
            ]
        ),
        .testTarget(
            name: "ProjectMemoryAppTests",
            dependencies: ["ProjectMemoryApp"]
        )
    ]
)
