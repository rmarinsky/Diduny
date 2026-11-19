// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PapugaKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PapugaKit", targets: ["PapugaKit"]),
    ],
    targets: [
        .target(
            name: "PapugaKit",
            path: "Sources/PapugaKit",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PapugaKitTests",
            dependencies: ["PapugaKit"],
            path: "Tests/PapugaKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
