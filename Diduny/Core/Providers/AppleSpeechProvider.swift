import Foundation

/// Apple speech recognition on this Mac: live text (`AppleLiveTranscriptionService`) and after Stop.
/// Languages and availability come from macOS at run time (`AppleBenchmarkEngine`, ADR-0012 D1).
struct AppleSpeechProvider: STTProviderModule {
    static let defaultModelID = STTProviderID.appleSpeech

    let id = STTProviderID.appleSpeech
    let displayName = "Apple Speech"
    let requiresKey = false
    let models = [
        STTModel(
            id: defaultModelID,
            displayName: "Apple Speech",
            capabilities: STTModelCapabilities(
                batch: BatchCaps(
                    maxDurationSeconds: nil,
                    maxFileBytes: nil,
                    diarization: false,
                    maxSpeakers: nil,
                    translation: nil
                ),
                realtime: RealtimeCaps(
                    maxSessionSeconds: nil,
                    idleTimeoutSeconds: nil,
                    liveQuality: .final,
                    diarization: false,
                    manualCommit: false,
                    translation: nil
                ),
                languages: .system,
                // Apple cannot detect the language; the app passes a speech language hint.
                autoLanguageDetection: false,
                batchDeletion: .none,
                realtimeDeletion: .none
            )
        )
    ]
    let traits = EngineTraits(
        runsOn: .thisMac,
        obtainedBy: .system,
        needs: [.macOSSpeech],
        recommended: .none,
        languages: .system
    )
}
