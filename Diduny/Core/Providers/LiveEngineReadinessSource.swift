import Foundation

/// The live `EngineReadinessSource` (ADR-0012 D1): whether each engine can run on this Mac now.
/// Diduny Cloud reads ready here; sign-in is checked at Start (`canStartRecording`), as today.
@MainActor
struct LiveEngineReadinessSource: EngineReadinessSource {
    var hasKey: (String) -> Bool = { ProviderKeyStore.shared.hasKey(for: $0) }
    var isAppleSilicon: () -> Bool = { ParakeetModelStore.isSupportedHardware }
    var isParakeetDownloaded: () -> Bool = { ParakeetModelStore.isDownloaded }
    var appleSpeechOnThisMac: () -> Bool = { AppleBenchmarkEngine().availability() == .ready }

    func readiness(of engine: EngineID) -> EngineReadiness {
        guard let module = ProviderRegistry.shared.module(id: engine.rawValue) else { return .unavailable }
        if module.requiresKey, !hasKey(module.id) { return .needsKey }
        if engine == .appleSpeech { return appleSpeechOnThisMac() ? .ready : .unavailable }
        guard case let .download(bytes) = module.traits.obtainedBy,
              module.traits.needs.contains(.appleSilicon) else { return .ready }
        if !isAppleSilicon() { return .unsupportedHardware }
        return isParakeetDownloaded() ? .ready : .notDownloaded(bytes: bytes)
    }
}
