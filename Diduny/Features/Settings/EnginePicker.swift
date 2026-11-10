import SwiftUI

/// One entry in a per-job "Engine" picker.
struct EngineOption: Identifiable, Equatable {
    /// "diduny-cloud", "local-whisper", or "<providerID>/<modelID>" for BYOK models.
    let id: String
    let title: String
    /// Non-nil = listed but disabled, with this reason.
    let disabledReason: String?
    let hint: String?
}

/// Builds picker entries for a job. Diduny Cloud and Local Whisper are always listed (as today);
/// BYOK models appear only when their key is stored, disabled with a reason when the router says unsupported.
@MainActor
enum EngineOptions {
    static func translationAvailability() -> (signedIn: Bool, available: Bool) {
        let signedIn = AuthService.hasStoredSession
        let available = UsageService.canOfferCloudTranscription(
            hasStoredSession: signedIn,
            usage: UsageService.shared.cachedUsage
        )
        return (signedIn, available)
    }

    static let byokJobs: Set<STTJob> = [.dictation, .dictationTranslation, .meeting]
    /// Parakeet and Apple run after Stop, so they are offered where the flow transcribes the saved capture.
    static let onDeviceJobs: Set<STTJob> = [.dictation, .dictationTranslation, .meeting, .meetingTranslation, .file]

    /// Parakeet V3 / Apple entries: listed when ready on this Mac; translation adds the Diduny text step.
    static func onDeviceOptions(for job: STTJob, context: RoutingContext, signedIn: Bool) -> [EngineOption] {
        let engines: [(String, any BenchmarkEngine)] = [
            (STTProviderID.parakeet, ParakeetBenchmarkEngine()),
            (STTProviderID.appleSpeech, AppleBenchmarkEngine())
        ]
        return engines.compactMap { id, engine in
            guard engine.availability() == .ready else { return nil }
            // Apple streams live text for dictation and meetings; Parakeet transcribes after Stop (like Handy).
            let translates = job == .dictationTranslation || job == .meetingTranslation
            let live = id == STTProviderID.appleSpeech && job != .file && job != .meetingTranslation
            let plan = ExecutionPlan(mode: live ? .live : .afterStop, translation: translates ? .didunyStep : .none)
            if translates, !context.didunyTranslationAvailable {
                return EngineOption(id: id, title: engine.name, disabledReason: reasonText(.translationNeedsDiduny, signedIn: signedIn), hint: nil)
            }
            return EngineOption(id: id, title: "\(engine.name) · \(planLabel(plan, job: job))", disabledReason: nil,
                                hint: (live ? String(localized: "Runs on this Mac. Text appears while you speak.") : String(localized: "Runs on this Mac after you press Stop.")) + (translates ? " " + String(localized: "Diduny translates the text and uses your Diduny quota.") : ""))
        }
    }

    static func context(keyStore: ProviderKeyStore = .shared, registry: ProviderRegistry = .shared) -> RoutingContext {
        RoutingContext(
            providersWithKey: Set(registry.modules.filter { keyStore.hasKey(for: $0.id) }.map(\.id)),
            didunyTranslationAvailable: translationAvailability().available
        )
    }

    static func options(
        for request: JobRequest,
        registry: ProviderRegistry = .shared,
        context: RoutingContext,
        signedIn: Bool
    ) -> [EngineOption] {
        let diduny = EngineOption(id: STTProviderID.didunyCloud, title: builtInTitle("Diduny Cloud", job: request.job, local: false), disabledReason: nil, hint: nil)
        // Live two-way meeting translation runs only on Diduny Cloud.
        guard request.job != .meetingTranslation else {
            // Own engines: Parakeet / Apple transcribe after Stop, then the final text is translated once.
            return [diduny] + onDeviceOptions(for: .meetingTranslation, context: context, signedIn: signedIn) + registry.modules.filter { $0.requiresKey && context.providersWithKey.contains($0.id) }.map {
                EngineOption(id: "\($0.id)/\($0.models.first?.id ?? "")", title: $0.displayName, disabledReason: String(localized: "can't translate live"), hint: nil)
            }
        }
        var result = [
            diduny,
            EngineOption(id: STTProviderID.localWhisper, title: builtInTitle("Local Whisper", job: request.job, local: true), disabledReason: nil, hint: nil)
        ]
        if onDeviceJobs.contains(request.job) {
            result += onDeviceOptions(for: request.job, context: context, signedIn: signedIn)
        }
        // BYOK engines run only where the recording flow is wired to them (dictation, dictation translation, live meetings).
        guard byokJobs.contains(request.job) else { return result }
        for module in registry.modules where module.requiresKey && context.providersWithKey.contains(module.id) {
            for model in module.models {
                let name = "\(module.displayName) \(model.displayName)"
                let id = "\(module.id)/\(model.id)"
                switch JobRouter.plan(request, providerID: module.id, requiresKey: true, model: model, context: context) {
                case let .plan(plan):
                    // Meetings are wired for live streaming only.
                    if request.job == .meeting, plan.mode != .live { continue }
                    result.append(EngineOption(id: id, title: "\(name) · \(planLabel(plan, job: request.job))", disabledReason: nil, hint: hint(plan, job: request.job)))
                case .unsupported(.noUsableMode):
                    continue
                case let .unsupported(reason):
                    result.append(EngineOption(id: id, title: name, disabledReason: reasonText(reason, signedIn: signedIn), hint: nil))
                }
            }
        }
        return result
    }

    private static func builtInTitle(_ name: String, job: STTJob, local: Bool) -> String {
        switch (job, local) {
        case (.file, false): "\(name) · " + String(localized: "after upload")
        case (.file, true): name
        case (.dictationTranslation, true): "\(name) · " + String(localized: "after Stop (English only)")
        case (_, true): "\(name) · " + String(localized: "live preview")
        case (_, false): "\(name) · " + String(localized: "live")
        }
    }

    static func planLabel(_ plan: ExecutionPlan, job: STTJob) -> String {
        var parts: [String] = []
        switch plan.mode {
        case .live: parts.append(String(localized: "live"))
        case .afterStop: parts.append(String(localized: "after Stop"))
        case .batch, .chunked: parts.append(String(localized: "after upload"))
        }
        if plan.translation == .didunyStep { parts[0] += " + " + String(localized: "Diduny translation") }
        if plan.speakerLabels { parts.append(String(localized: "speaker labels")) }
        if plan.noSpeakerLabelsNote || (job == .meeting && !plan.speakerLabels) {
            parts.append(String(localized: "no speaker labels"))
        }
        return parts.joined(separator: " · ")
    }

    private static func hint(_ plan: ExecutionPlan, job: STTJob) -> String {
        if plan.translation == .didunyStep {
            return String(localized: "Transcribed by the provider; Diduny translates the text and uses your Diduny quota.")
        }
        switch (job, plan.mode) {
        case (.meeting, _) where !plan.speakerLabels:
            return String(localized: "No speaker labels with this engine. Meetings are transcribed live and not re-processed afterwards.")
        case (_, .live):
            return String(localized: "Text appears while you speak. Final text is pasted right after Stop.")
        case (_, .afterStop):
            return String(localized: "Slower: the recording is transcribed after you press Stop.")
        default:
            return String(localized: "Speaker labels available for files.")
        }
    }

    static func reasonText(_ reason: UnsupportedReason, signedIn: Bool) -> String {
        switch reason {
        case .translationNeedsDiduny:
            signedIn ? String(localized: "Diduny quota used up") : String(localized: "needs Diduny sign-in")
        case let .language(code):
            String(format: String(localized: "can't transcribe %@"), code)
        case .fileTooLong:
            String(localized: "file too long")
        case .noKey, .noUsableMode:
            String(localized: "unavailable")
        }
    }
}
