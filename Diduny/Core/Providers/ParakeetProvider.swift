import Foundation

/// Parakeet V3 on this Mac (FluidAudio, Apple silicon): transcribes the saved capture after Stop.
/// Availability stays on `ParakeetBenchmarkEngine` / `ParakeetModelStore` (ADR-0012 D1).
struct ParakeetProvider: STTProviderModule {
    static let defaultModelID = STTProviderID.parakeet
    /// "About 480 MB" (Local models, `OfflineModelsSettingsView`).
    static let downloadBytes: Int64 = 480_000_000

    let id = STTProviderID.parakeet
    let displayName = "Parakeet V3"
    let requiresKey = false
    let models = [
        STTModel(
            id: defaultModelID,
            displayName: "Parakeet V3",
            capabilities: STTModelCapabilities(
                batch: BatchCaps(
                    maxDurationSeconds: nil,
                    maxFileBytes: nil,
                    diarization: false,
                    maxSpeakers: nil,
                    translation: nil
                ),
                realtime: nil,
                // 25 languages are display data (`EngineLanguages.parakeet`); nothing is blocked up front.
                languages: .all,
                autoLanguageDetection: true,
                batchDeletion: .none,
                realtimeDeletion: .none
            )
        )
    ]
    let traits = EngineTraits(
        runsOn: .thisMac,
        obtainedBy: .download(bytes: downloadBytes),
        needs: [.download, .appleSilicon],
        recommended: .engine,
        languages: EngineLanguages.parakeet
    )
}
