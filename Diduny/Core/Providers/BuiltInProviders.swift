import Foundation

/// Diduny Cloud (ears-proxy → Soniox): CloudRealtimeService live + CloudTranscriptionService after Stop / files.
struct DidunyCloudProvider: STTProviderModule {
    static let defaultModelID = "diduny-cloud"

    let id = STTProviderID.didunyCloud
    let displayName = "Diduny Cloud"
    let requiresKey = false
    let models = [
        STTModel(
            id: defaultModelID,
            displayName: "Diduny Cloud",
            capabilities: STTModelCapabilities(
                batch: BatchCaps(
                    maxDurationSeconds: nil,
                    maxFileBytes: nil,
                    diarization: true,
                    maxSpeakers: nil,
                    translation: TranslationCaps(oneWay: true, twoWay: true)
                ),
                realtime: RealtimeCaps(
                    maxSessionSeconds: nil,
                    idleTimeoutSeconds: nil,
                    liveQuality: .final,
                    diarization: true,
                    manualCommit: true,
                    translation: TranslationCaps(oneWay: true, twoWay: true)
                ),
                languages: .all,
                autoLanguageDetection: true,
                batchDeletion: .unverified,
                realtimeDeletion: .unverified
            )
        )
    ]
    let traits = EngineTraits(
        runsOn: .cloud,
        obtainedBy: .builtIn,
        needs: [.account],
        recommended: .none,
        languages: EngineLanguages.didunyCloud
    )
}

/// Local Whisper on this Mac: WhisperTranscriptionService after Stop / files,
/// LocalWhisperStreamingService for the live preview. Whisper translates to English only.
struct LocalWhisperProvider: STTProviderModule {
    static let defaultModelID = "local-whisper"

    let id = STTProviderID.localWhisper
    let displayName = "Local Whisper"
    let requiresKey = false
    let models = [
        STTModel(
            id: defaultModelID,
            displayName: "Whisper",
            capabilities: STTModelCapabilities(
                batch: BatchCaps(
                    maxDurationSeconds: nil,
                    maxFileBytes: nil,
                    diarization: false,
                    maxSpeakers: nil,
                    translation: TranslationCaps(oneWay: true, twoWay: false)
                ),
                realtime: RealtimeCaps(
                    maxSessionSeconds: nil,
                    idleTimeoutSeconds: nil,
                    liveQuality: .preview,
                    diarization: false,
                    manualCommit: false,
                    translation: nil
                ),
                languages: .all,
                autoLanguageDetection: true,
                batchDeletion: .none,
                realtimeDeletion: .none
            )
        )
    ]
    /// Download size of the recommended model, from the catalog; models range 75 MB to 2.9 GB.
    let traits = EngineTraits(
        runsOn: .thisMac,
        obtainedBy: .download(bytes: WhisperModelManager.availableModels.first(where: \.isRecommended)?.sizeBytes ?? 0),
        needs: [.download],
        recommended: .model(id: WhisperModelManager.WhisperModel.recommendedName),
        languages: EngineLanguages.whisper
    )
}

/// BYOK plans for a job's selection. Which engine a mode runs is `RunTimeRouting` (WP-17).
enum ProviderEngineRouting {
    /// Plan for a BYOK selection of `providerID`, or nil when another provider is selected or the router refuses it.
    static func byokPlan(
        for job: STTJob,
        providerID: String,
        selection: JobProviderSelection,
        registry: ProviderRegistry = .shared,
        context: RoutingContext
    ) -> ExecutionPlan? {
        guard selection.providerID == providerID,
              let module = registry.module(id: providerID),
              let model = module.models.first(where: { $0.id == selection.modelID }) ?? module.models.first,
              case let .plan(plan) = JobRouter.plan(
                  JobRequest(job: job),
                  providerID: module.id,
                  requiresKey: module.requiresKey,
                  model: model,
                  context: context
              )
        else { return nil }
        return plan
    }
}

/// Diduny translation endpoint (`GET /api/v1/translations`), the same one the text translation panel uses.
struct DidunyTextTranslationService: TextTranslationProtocol {
    func translate(text: String, sourceLanguage: String, targetLanguage: String) async throws -> String {
        try await TextTranslationClient.requestTranslation(
            sourceText: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }
}

/// Dictation translation with a BYOK engine: the provider transcribes, then the Diduny endpoint translates the text.
enum ByokTranslationStep {
    enum StartDecision: Equatable {
        /// The BYOK provider is not selected for translation: the existing Cloud/Local flow runs.
        case notSelected
        case run(ExecutionPlan)
        /// Selected with a key, but the Diduny translation step is unusable (signed out or no quota).
        case translationUnavailable(signedIn: Bool)
    }

    static func startDecision(
        providerID: String,
        selection: JobProviderSelection,
        plan: ExecutionPlan?,
        context: RoutingContext,
        signedIn: Bool
    ) -> StartDecision {
        guard selection.providerID == providerID, context.providersWithKey.contains(providerID) else {
            return .notSelected
        }
        if let plan { return .run(plan) }
        return context.didunyTranslationAvailable ? .notSelected : .translationUnavailable(signedIn: signedIn)
    }

    /// Translates the transcript; on failure returns it untranslated with `translated == false`.
    static func translate(
        _ transcript: String,
        targetLanguage: String,
        translator: TextTranslationProtocol
    ) async -> (text: String, translated: Bool) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (transcript, true) }
        do {
            return try await (translator.translate(text: trimmed, sourceLanguage: "auto", targetLanguage: targetLanguage), true)
        } catch {
            return (transcript, false)
        }
    }
}
