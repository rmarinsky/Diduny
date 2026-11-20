// swift-tools-version: 5.9
import PackageDescription

// Shared with AppCat: both apps read browser profile data that macOS privacy can block.
let package = Package(
    name: "BrowserDataAccess",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BrowserDataAccess", targets: ["BrowserDataAccess"])],
    targets: [
        .target(name: "BrowserDataAccess"),
        .testTarget(name: "BrowserDataAccessTests", dependencies: ["BrowserDataAccess"]),
    ]
)
