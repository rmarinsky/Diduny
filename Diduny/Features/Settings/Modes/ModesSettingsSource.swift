import Foundation

/// Push-to-talk options of one mode (05 2.1.2): "Key to hold or tap", "Tap to start and stop",
/// "Hold to record", "Hold for".
struct ModePushToTalk: Equatable, Sendable {
    var key: PushToTalkKey
    var toggleEnabled: Bool
    /// 2 or 3; read only while `toggleEnabled`.
    var tapCount: Int
    var holdEnabled: Bool
    var holdDelaySeconds: TimeInterval
}

/// "Stop after silence" of one mode.
struct ModeSilence: Equatable, Sendable {
    var enabled: Bool
    var seconds: Double
}

/// What Settings > Modes reads and writes. The live adapter (`LiveModesSettingsSource`) sits on today's
/// settings; WP-13 replaces its engine half with `ModeDefaults` (ADR-0012 D4). Tests use an in-memory fake.
@MainActor
protocol ModesSettingsSource: AnyObject {
    /// Default engine of a mode other than `.meeting`.
    func engine(for job: STTJob) -> EngineID
    func setEngine(_ engine: EngineID, for job: STTJob)

    /// "Starts in" (`meetingTranscriptMode`).
    var meetingStartsIn: MeetingSegment { get set }
    func meetingEngine(for segment: MeetingSegment) -> EngineID
    func setMeetingEngine(_ engine: EngineID, for segment: MeetingSegment)

    /// Translation "Into" (`dictationTranslationTargetLanguage`).
    var dictationTranslationTarget: String { get set }
    var yourLanguages: [String] { get }
    /// "Between": the one pair (`defaultTranslationLanguagePairID`); nil with fewer than two languages.
    var translationPair: TranslationLanguagePair? { get }
    var offeredTranslationPairs: [TranslationLanguagePair] { get }
    func selectTranslationPair(_ pair: TranslationLanguagePair)

    var meetingTranslationShowOriginal: Bool { get set }
    var meetingSuggestionsEnabled: Bool { get set }

    /// `.dictation` and `.dictationTranslation` only.
    func pushToTalk(for job: STTJob) -> ModePushToTalk
    func setPushToTalk(_ value: ModePushToTalk, for job: STTJob)

    /// Every mode except `.file`.
    func silence(for job: STTJob) -> ModeSilence
    func setSilence(_ value: ModeSilence, for job: STTJob)

    /// 1...3; every mode except `.file`.
    func pressCount(for job: STTJob) -> Int
    func setPressCount(_ count: Int, for job: STTJob)
}

/// The mode x engine rules (05 2.1.1 and section 3). WP-13's `ModeEngineRules` (ADR-0012 D3) conforms to this
/// once it lands; until then `InterimModeEngineRules` holds the same two rules.
protocol ModeEngineRuleSource {
    /// Engines a mode (and Meeting segment) offers, in `all` order. Readiness is applied by the caller.
    func offeredEngines(job: STTJob, segment: MeetingSegment?, all: [EngineCapabilities]) -> [EngineCapabilities]
    /// The Meeting segment "Use one engine for everything" moves to for `engine` (05 section 3 table).
    func segment(implyingEngine engine: EngineCapabilities) -> MeetingSegment
}

/// Stand-in for WP-13's `ModeEngineRules`. Reads capabilities only, never the engine id (rule C1).
struct InterimModeEngineRules: ModeEngineRuleSource {
    func offeredEngines(job: STTJob, segment: MeetingSegment?, all: [EngineCapabilities]) -> [EngineCapabilities] {
        all.filter { caps in
            switch job {
            case .file:
                return caps.traits.runsOn == .thisMac
            case .meeting:
                switch segment ?? .cloud {
                case .thisMac: return caps.traits.runsOn == .thisMac && caps.liveMeetingText != .none
                case .cloud: return caps.traits.runsOn == .cloud
                case .recordOnly: return true
                }
            case .dictation, .dictationTranslation, .meetingTranslation:
                return true
            }
        }
    }

    func segment(implyingEngine engine: EngineCapabilities) -> MeetingSegment {
        if engine.traits.runsOn == .cloud { return .cloud }
        return engine.liveMeetingText == .none ? .recordOnly : .thisMac
    }
}
