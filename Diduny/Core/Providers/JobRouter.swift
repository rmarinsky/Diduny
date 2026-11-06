import Foundation

struct JobRequest: Equatable, Sendable {
    var job: STTJob
    /// Language codes the user expects (ISO-639-1); empty or "auto" means auto-detect.
    var languages: [String] = []
    /// Meetings and files: user wants speaker labels.
    var speakerLabels: Bool = false
    /// Meetings: live two-way translation is on.
    var meetingTranslation: Bool = false
    /// Record only: transcribe after Stop through `batch` even when the model streams live.
    var afterStop: Bool = false
    /// The selected local model can run the engine's own batch translation into the target language.
    /// Whisper: only multilingual non-Turbo models, and only into English (bug 9). Other engines: true.
    var ownBatchTranslationUsable: Bool = true
    /// Files only.
    var fileDurationSeconds: TimeInterval?
    var fileBytes: Int64?
}

extension JobRequest {
    /// Bug 9: Whisper's own translation per model. Only multilingual non-Turbo models translate, and only
    /// into English; `model` is the catalog name (`ggml-large-v3-turbo`). Unknown or nil models do not.
    static func whisperTranslationUsable(model: String?, target: String) -> Bool {
        guard target == "en",
              let entry = WhisperModelManager.availableModels.first(where: { $0.name == model }) else { return false }
        return entry.translatesToEnglish
    }
}

struct RoutingContext: Equatable, Sendable {
    var providersWithKey: Set<String>
    /// Signed in to Diduny with translation quota left (the Diduny translation step is usable).
    var didunyTranslationAvailable: Bool
}

struct ExecutionPlan: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// Realtime stream; dictation sends a manual commit on Stop.
        case live
        /// Record, then transcribe via batch after Stop.
        case afterStop
        /// Single batch request (files).
        case batch
        /// Chunked batch with overlap, stitched in order.
        case chunked(chunkSeconds: TimeInterval, overlapSeconds: TimeInterval)
    }

    enum Translation: Equatable, Sendable {
        case none
        /// The model translates in the same request/stream.
        case native
        /// Transcribe with the provider, then translate text only via the Diduny translation endpoint.
        case didunyStep
    }

    var mode: Mode
    var translation: Translation = .none
    var speakerLabels: Bool = false
    /// Speaker labels were requested but the plan cannot provide them.
    var noSpeakerLabelsNote: Bool = false
    /// Chunked files: speaker ids may differ between chunks.
    var speakerIDsMayDiffer: Bool = false
}

enum UnsupportedReason: Equatable, Sendable {
    case noKey
    case noUsableMode
    case language(String)
    case fileTooLong(maxSeconds: TimeInterval)
    case translationNeedsDiduny
}

enum RoutingResult: Equatable, Sendable {
    case plan(ExecutionPlan)
    case unsupported(UnsupportedReason)
}

struct PickerOption: Equatable, Sendable {
    let providerID: String
    let modelID: String
    let plan: ExecutionPlan
}

/// Pure routing: job + provider/model capabilities + languages → plan or reason. No network, no singletons.
enum JobRouter {
    static let chunkOverlapSeconds: TimeInterval = 2
    /// Used when a model declares no duration limit and the file is long.
    static let conservativeChunkSeconds: TimeInterval = 3600

    static func plan(
        _ request: JobRequest,
        providerID: String,
        requiresKey: Bool,
        model: STTModel,
        context: RoutingContext
    ) -> RoutingResult {
        if requiresKey, !context.providersWithKey.contains(providerID) {
            return .unsupported(.noKey)
        }
        let caps = model.capabilities
        if let unsupported = request.languages.first(where: { !caps.languages.supports($0) }) {
            return .unsupported(.language(unsupported))
        }
        switch request.job {
        case .dictation:
            return dictationPlan(request, caps, translate: false, context: context)
        case .dictationTranslation:
            return dictationPlan(request, caps, translate: true, context: context)
        case .meeting:
            return meetingPlan(request, caps, context: context)
        case .meetingTranslation:
            var translated = request
            translated.meetingTranslation = true
            return meetingPlan(translated, caps, context: context)
        case .file:
            return filePlan(request, caps)
        }
    }

    /// Models selectable for the job: only those with a plan. BYOK models without a key are not listed.
    static func pickerOptions(
        for request: JobRequest,
        registry: ProviderRegistry,
        context: RoutingContext
    ) -> [PickerOption] {
        registry.modules.flatMap { module in
            module.models.compactMap { model in
                guard case let .plan(plan) = self.plan(
                    request,
                    providerID: module.id,
                    requiresKey: module.requiresKey,
                    model: model,
                    context: context
                ) else { return nil }
                return PickerOption(providerID: module.id, modelID: model.id, plan: plan)
            }
        }
    }

    private static func dictationPlan(
        _ request: JobRequest,
        _ caps: STTModelCapabilities,
        translate: Bool,
        context: RoutingContext
    ) -> RoutingResult {
        let mode: ExecutionPlan.Mode
        let nativeOK: Bool
        if let realtime = caps.realtime, !request.afterStop {
            mode = .live
            nativeOK = realtime.translation?.oneWay == true
        } else if let batch = caps.batch {
            mode = .afterStop
            nativeOK = batch.translation?.oneWay == true && request.ownBatchTranslationUsable
        } else {
            return .unsupported(.noUsableMode)
        }
        var plan = ExecutionPlan(mode: mode)
        if translate {
            guard let translation = translation(nativeOK: nativeOK, context: context) else {
                return .unsupported(.translationNeedsDiduny)
            }
            plan.translation = translation
        }
        return .plan(plan)
    }

    private static func meetingPlan(
        _ request: JobRequest,
        _ caps: STTModelCapabilities,
        context: RoutingContext
    ) -> RoutingResult {
        // Translation the model cannot do live both ways runs after Stop with the Diduny step, when it can.
        let liveTwoWay = caps.realtime?.translation?.twoWay == true
        let translationAfterStop = request.meetingTranslation && !liveTwoWay && caps.batch != nil
        var plan: ExecutionPlan
        let diarization: Bool
        let nativeTwoWay: Bool
        if let realtime = caps.realtime, !request.afterStop, !translationAfterStop {
            plan = ExecutionPlan(mode: .live)
            diarization = realtime.diarization
            nativeTwoWay = realtime.translation?.twoWay == true
        } else if let batch = caps.batch {
            plan = ExecutionPlan(mode: .afterStop)
            // After-Stop labels are `EngineCapabilities.speakerLabelsAfterStop`, i.e. batch diarization.
            diarization = batch.diarization
            nativeTwoWay = batch.translation?.twoWay == true
        } else {
            return .unsupported(.noUsableMode)
        }
        if request.speakerLabels {
            plan.speakerLabels = diarization
            plan.noSpeakerLabelsNote = !diarization
        }
        if request.meetingTranslation {
            guard let translation = translation(nativeOK: nativeTwoWay, context: context) else {
                return .unsupported(.translationNeedsDiduny)
            }
            plan.translation = translation
        }
        return .plan(plan)
    }

    private static func filePlan(_ request: JobRequest, _ caps: STTModelCapabilities) -> RoutingResult {
        guard let batch = caps.batch else { return .unsupported(.noUsableMode) }
        let duration = request.fileDurationSeconds ?? 0
        if let maxSeconds = batch.maxDurationSeconds, duration > maxSeconds {
            return .unsupported(.fileTooLong(maxSeconds: maxSeconds))
        }
        var plan = ExecutionPlan(mode: .batch)
        if request.speakerLabels {
            plan.speakerLabels = batch.diarization
            plan.noSpeakerLabelsNote = !batch.diarization
        }
        if let chunkSeconds = chunkSeconds(duration: duration, bytes: request.fileBytes, batch: batch) {
            plan.mode = .chunked(chunkSeconds: chunkSeconds, overlapSeconds: chunkOverlapSeconds)
            plan.speakerIDsMayDiffer = plan.speakerLabels
        }
        return .plan(plan)
    }

    private static func chunkSeconds(duration: TimeInterval, bytes: Int64?, batch: BatchCaps) -> TimeInterval? {
        if let maxBytes = batch.maxFileBytes, let bytes, bytes > maxBytes, duration > 0 {
            // 10% headroom so each chunk stays under the size limit.
            let ratio = Double(maxBytes) / Double(bytes) * 0.9
            return max(chunkOverlapSeconds * 2, (duration * ratio).rounded(.down))
        }
        if batch.maxDurationSeconds == nil, duration > conservativeChunkSeconds {
            return conservativeChunkSeconds
        }
        return nil
    }

    private static func translation(nativeOK: Bool, context: RoutingContext) -> ExecutionPlan.Translation? {
        if nativeOK { return .native }
        return context.didunyTranslationAvailable ? .didunyStep : nil
    }
}
