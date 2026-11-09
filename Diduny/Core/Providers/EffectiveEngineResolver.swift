import Foundation

/// The engine a recording actually runs (ADR-0012 D3, plan default 16 rest). Pure over its inputs.
enum EffectiveEngineResolver {
    enum Result: Equatable {
        case engine(EngineID, modelID: String?)
        case fallback(EngineID, modelID: String?, because: EngineReadiness)
        /// Nothing can run: Record only keeps the audio unprocessed, Files refuse.
        case none(EngineReadiness)
    }

    /// Downloaded Whisper models (file names such as `ggml-large-v3-turbo`) and the selected one.
    struct WhisperState: Equatable {
        var downloaded: Set<String>
        var selected: String?
    }

    /// The override wins over the mode default. A mode default of Parakeet V3 that is not ready falls back to Whisper
    /// Large v3 Turbo if downloaded, else the selected Whisper model if downloaded, else Apple Speech if ready.
    @MainActor
    static func resolve(
        job: STTJob,
        segment: MeetingSegment? = nil,
        override: JobProviderSelection? = nil,
        defaults: ModeDefaults,
        readiness: any EngineReadinessSource,
        whisper: WhisperState
    ) -> Result {
        let selection = override ?? (job == .meeting
            ? defaults.selection(for: segment ?? defaults.meetingStartsIn)
            : defaults.selection(for: job))
        guard let engine = EngineID(rawValue: selection.providerID) else { return .none(.unavailable) }
        let state = readiness.readiness(of: engine)
        if state == .ready { return .engine(engine, modelID: selection.modelID) }
        // An explicit pick never silently changes engine: Start refuses and names Local models.
        guard engine == .parakeet, override == nil else { return .none(state) }

        let turbo = WhisperModelManager.WhisperModel.recommendedName
        if whisper.downloaded.contains(turbo) {
            return .fallback(.whisper, modelID: turbo, because: state)
        }
        if let selected = whisper.selected, whisper.downloaded.contains(selected) {
            return .fallback(.whisper, modelID: selected, because: state)
        }
        if readiness.readiness(of: .appleSpeech) == .ready {
            return .fallback(.appleSpeech, modelID: nil, because: state)
        }
        return .none(state)
    }
}
