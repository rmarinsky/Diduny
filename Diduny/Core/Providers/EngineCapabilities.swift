import Foundation

/// The five engines. Raw values are today's `STTProviderID` strings (ADR-0012 D1).
enum EngineID: String, CaseIterable, Codable, Sendable {
    case didunyCloud = "diduny-cloud"
    case elevenLabs = "elevenlabs"
    case whisper = "local-whisper"
    case parakeet = "parakeet-v3"
    case appleSpeech = "apple-speech"
}

/// Meeting transcript segment: the value of "Starts in" and the suffix of the per-segment default key
/// (ADR-0012 D4: `thisMac` | `cloud` | `recordOnly`).
enum MeetingSegment: String, CaseIterable, Codable, Sendable {
    case thisMac
    case cloud
    case recordOnly
}

/// Text shown while recording: final words, a preview that is replaced after Stop, or none.
enum LiveText: Equatable, Sendable {
    case final
    case preview
    case none
}

/// Engine-level facts that model capabilities cannot express (`STTProviderModule.traits`).
struct EngineTraits: Equatable, Sendable {
    enum RunsOn: Equatable, Sendable { case cloud, thisMac }
    enum ObtainedBy: Equatable, Sendable { case builtIn, ownKey, download(bytes: Int64), system }
    enum Need: Equatable, Sendable { case account, ownKey, download, appleSilicon, macOSSpeech }
    enum Recommended: Equatable, Sendable { case none, engine, model(id: String) }

    var runsOn: RunsOn
    var obtainedBy: ObtainedBy
    var needs: [Need]
    var recommended: Recommended
    /// Display list only; it never gates a recording (routing reads `STTModelCapabilities.languages`).
    var languages: EngineLanguageList
}

enum AfterStopLabels: Equatable, Sendable {
    case none
    case yes(maxSpeakers: Int?)
}

enum DictationTranslation: Equatable, Sendable {
    /// The engine translates into any language itself (live).
    case itself
    /// The engine translates only into English itself; any other language is translated by Diduny.
    case englishOnlyItselfPlusDiduny
    /// The engine makes the text; Diduny translates it.
    case byDiduny
}

enum MeetingTranslation: Equatable, Sendable {
    case liveBothDirections
    case afterStopIntoSecondLanguage
}

/// The capability record every menu, caption and table cell reads. Derived from the module's
/// `models[].capabilities` and `traits`; UI never branches on the provider id.
struct EngineCapabilities: Equatable, Sendable {
    let id: EngineID
    let traits: EngineTraits
    let liveDictation: LiveText
    let liveMeetingText: LiveText
    let speakerLabelsLive: Bool
    let speakerLabelsAfterStop: AfterStopLabels
    let dictationTranslation: DictationTranslation
    let meetingTranslation: MeetingTranslation
    let returnsOriginalWithTranslation: Bool

    /// `module` must be one of the five engines (a `ProviderRegistry.shared` module).
    /// `activeWhisperModel` is the selected Whisper model; it decides whether batch translation
    /// into English is usable (Turbo and `.en` models do not translate).
    static func make(_ module: any STTProviderModule, activeWhisperModel: WhisperModelManager.WhisperModel?) -> Self {
        guard let id = EngineID(rawValue: module.id) else {
            preconditionFailure("\(module.id) is not an engine")
        }
        let realtime = module.models.lazy.compactMap(\.capabilities.realtime).first
        let batch = module.models.lazy.compactMap(\.capabilities.batch).first
        let live = realtime?.liveQuality ?? .none

        let dictationTranslation: DictationTranslation
        if realtime?.translation?.oneWay == true {
            dictationTranslation = .itself
        } else if batch?.translation?.oneWay == true, activeWhisperModel?.translatesToEnglish ?? true {
            // Only Whisper declares batch-only one-way translation: its translate pass targets English.
            dictationTranslation = .englishOnlyItselfPlusDiduny
        } else {
            dictationTranslation = .byDiduny
        }
        let twoWay = realtime?.translation?.twoWay == true

        return EngineCapabilities(
            id: id,
            traits: module.traits,
            liveDictation: live,
            liveMeetingText: live,
            speakerLabelsLive: realtime?.diarization == true,
            speakerLabelsAfterStop: batch?.diarization == true ? .yes(maxSpeakers: batch?.maxSpeakers) : .none,
            dictationTranslation: dictationTranslation,
            meetingTranslation: twoWay ? .liveBothDirections : .afterStopIntoSecondLanguage,
            returnsOriginalWithTranslation: twoWay
        )
    }
}
