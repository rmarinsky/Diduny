import Foundation

/// Whether an engine can run now. Separate from what it can do (`EngineCapabilities`).
enum EngineReadiness: Equatable, Sendable {
    case ready
    case needsKey
    case notDownloaded(bytes: Int64)
    case unsupportedHardware
    case signedOut
    case noQuota
    case unavailable
}

/// One source of readiness for every engine; tests use a fake.
protocol EngineReadinessSource {
    @MainActor func readiness(of engine: EngineID) -> EngineReadiness
}
