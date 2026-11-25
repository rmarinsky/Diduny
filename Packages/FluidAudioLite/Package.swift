// swift-tools-version: 6.2
import PackageDescription

// XcodeGen cannot set package traits. This wrapper pulls FluidAudio without its default
// `NemoTextProcessing` trait: that Rust text-normalization engine serves only TTS and
// ITN, which Diduny does not use, and adds about 8 MB per architecture.
let package = Package(
    name: "FluidAudioLite",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FluidAudioLite", targets: ["FluidAudioLite"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7", traits: []),
    ],
    targets: [
        .target(
            name: "FluidAudioLite",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
