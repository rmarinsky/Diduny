// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PapugaKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PapugaCore", targets: ["PapugaCore"]),
    ],
    targets: [
        .target(
            name: "PapugaCore",
            path: "Sources/PapugaCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PapugaCoreTests",
            dependencies: ["PapugaCore"],
            path: "Tests/PapugaCoreTests"
        ),
    ]
)
