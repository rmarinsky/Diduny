@testable import Diduny

/// Fake for the `EngineReadinessSource` seam (test-plan 2.5): engines not set are ready; records each query.
@MainActor
final class FakeEngineReadinessSource: EngineReadinessSource {
    var states: [EngineID: EngineReadiness]
    private(set) var requested: [EngineID] = []

    init(_ states: [EngineID: EngineReadiness] = [:]) {
        self.states = states
    }

    func readiness(of engine: EngineID) -> EngineReadiness {
        requested.append(engine)
        return states[engine] ?? .ready
    }
}
