import Foundation

extension STTProviderID {
    static let elevenLabs = "elevenlabs"
}

/// ElevenLabs Scribe, bring-your-own-key. Calls go from the Mac straight to api.elevenlabs.io.
struct ElevenLabsProvider: STTProviderModule {
    static let batchModelID = "scribe_v2"
    static let realtimeModelID = "scribe_v2_realtime"
    static let baseURL = URL(string: "https://api.elevenlabs.io")!

    let id = STTProviderID.elevenLabs
    let displayName = "ElevenLabs"
    let requiresKey = true
    let models = [
        STTModel(
            id: batchModelID,
            displayName: "Scribe v2",
            capabilities: STTModelCapabilities(
                batch: BatchCaps(
                    maxDurationSeconds: 10 * 3600,
                    maxFileBytes: 3_000_000_000,
                    diarization: true,
                    maxSpeakers: 32,
                    translation: nil
                ),
                realtime: nil,
                // 94 published languages are display data (`EngineLanguages.elevenLabs`); nothing is blocked up front.
                languages: .all,
                autoLanguageDetection: true,
                batchDeletion: .byID,
                realtimeDeletion: .unverified
            )
        ),
        STTModel(
            id: realtimeModelID,
            displayName: "Scribe v2 Realtime",
            capabilities: STTModelCapabilities(
                batch: nil,
                realtime: RealtimeCaps(
                    maxSessionSeconds: nil,
                    idleTimeoutSeconds: 15,
                    liveQuality: .final,
                    diarization: false,
                    manualCommit: true,
                    translation: nil
                ),
                languages: .all,
                autoLanguageDetection: true,
                batchDeletion: .none,
                realtimeDeletion: .unverified
            )
        )
    ]
    let traits = EngineTraits(
        runsOn: .cloud,
        obtainedBy: .ownKey,
        needs: [.ownKey],
        recommended: .none,
        languages: EngineLanguages.elevenLabs
    )
}
