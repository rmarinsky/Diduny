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
}

/// The mode x engine rules (05 2.1.1 and section 3), backed by WP-13's `ModeEngineRules` (ADR-0012 D3).
protocol ModeEngineRuleSource {
    /// Engines a mode (and Meeting segment) offers, in `all` order. Readiness is applied by the caller.
    func offeredEngines(job: STTJob, segment: MeetingSegment?, all: [EngineCapabilities]) -> [EngineCapabilities]
    /// The Meeting segment "Use one engine for everything" moves to for `engine` (05 section 3 table).
    func segment(implyingEngine engine: EngineCapabilities) -> MeetingSegment
}

/// WP-13's `ModeEngineRules` (ADR-0012 D3) as the Modes page reads it: one flat list in `all` order.
struct StandardModeEngineRules: ModeEngineRuleSource {
    func offeredEngines(job: STTJob, segment: MeetingSegment?, all: [EngineCapabilities]) -> [EngineCapabilities] {
        let offered = Set(ModeEngineRules.offeredEngines(job: job, segment: segment, available: all).flatMap(\.engines))
        return all.filter { offered.contains($0.id) }
    }

    func segment(implyingEngine engine: EngineCapabilities) -> MeetingSegment {
        ModeEngineRules.segment(implyingEngine: engine)
    }
}
