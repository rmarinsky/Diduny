import Foundation
import Observation

enum EdgeCommandAction: CaseIterable, Identifiable {
    case transcribe
    case translate
    case meeting
    case translateMeeting
    case batch

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .transcribe: String(localized: "Transcribe")
        case .translate: String(localized: "Translate")
        case .meeting: String(localized: "Record meeting")
        case .translateMeeting: String(localized: "Translate meeting")
        case .batch: String(localized: "Batch files")
        }
    }

    var icon: String {
        switch self {
        case .transcribe: "mic"
        case .translate: "globe"
        case .meeting: "person.2"
        case .translateMeeting: "person.2"
        case .batch: "tray.full"
        }
    }
}

enum EdgeCommandPanelPresentation: Equatable {
    case collapsed
    case commands(isCloud: Bool)
    case live(RecordingMode)
    case meetingSuggestion
}

/// What the meeting prompt reads from Settings > Modes > Meeting: "Starts in" and each segment's
/// default engine (02 section 7). Until WP-13 stores these, the controller builds it from today's settings.
struct MeetingPromptDefaults: Equatable {
    var startsIn: MeetingSegment
    var engines: [MeetingSegment: EngineID]

    /// Modes defaults (Proto:754): Cloud; This Mac Whisper, Cloud Diduny Cloud, Record only Parakeet V3.
    static let standard = Self(
        startsIn: .cloud,
        engines: [.thisMac: .whisper, .cloud: .didunyCloud, .recordOnly: .parakeet]
    )

    func engine(for segment: MeetingSegment) -> EngineID {
        engines[segment] ?? Self.standard.engines[segment] ?? .didunyCloud
    }
}

/// The meeting the prompt starts: its segment and that segment's default engine.
struct MeetingPromptStart: Equatable {
    let segment: MeetingSegment
    let engine: EngineID
}

struct MeetingSuggestion: Equatable {
    let meeting: DetectedMeeting
    let defaults: MeetingPromptDefaults
    /// For this prompt only (02 Q8 default): a click does not write Modes.
    var selectedSegment: MeetingSegment
    var isCloudAvailable: Bool

    var engine: EngineID {
        defaults.engine(for: selectedSegment)
    }

    /// Field label "Transcript after Stop" instead of "Engine".
    var isEngineAfterStop: Bool {
        selectedSegment == .recordOnly
    }

    var engineName: String {
        switch engine {
        case .didunyCloud: "Diduny Cloud"
        case .elevenLabs: "ElevenLabs"
        case .whisper: "Whisper"
        case .parakeet: "Parakeet V3"
        case .appleSpeech: "Apple Speech"
        }
    }

    var start: MeetingPromptStart {
        MeetingPromptStart(segment: selectedSegment, engine: engine)
    }

    func isSelectable(_ segment: MeetingSegment) -> Bool {
        segment != .cloud || isCloudAvailable
    }

    static func resolve(
        meeting: DetectedMeeting,
        defaults: MeetingPromptDefaults,
        cloudAvailable: Bool
    ) -> Self {
        Self(
            meeting: meeting,
            defaults: defaults,
            selectedSegment: defaults.startsIn == .cloud && !cloudAvailable ? .thisMac : defaults.startsIn,
            isCloudAvailable: cloudAvailable
        )
    }
}

@Observable
@MainActor
final class EdgeCommandPanelModel {
    /// Engines the tiles use on "As in Settings" (an input, see `CommandHomeDefaults`).
    var defaults: CommandHomeDefaults
    /// The one-recording engine pick. Never stored; consumed by a tile start, cleared by any other start.
    private(set) var pick: EngineID?
    /// Translate into, for the Translate tile only. Kept after Stop; never written to Settings.
    private(set) var target: String
    /// The saved pair, for the Translate meeting tile.
    var pair: TranslationLanguagePair
    var yourLanguages: [String]
    var isSignedIn: Bool
    var isExpanded = false
    var isShowingLiveFeedback = false
    /// Live recording is active but the user collapsed the panel to the edge tab.
    var isLiveFeedbackMinimized = false
    var meetingSuggestion: MeetingSuggestion?
    var meetingSuggestionsEnabled = SettingsStorage.shared.meetingSuggestionsEnabled
    var dockEdge: EdgeCommandPanelDockEdge = .right

    init(
        defaults: CommandHomeDefaults = .prototype,
        target: String = CommandHome.fallbackTarget,
        pair: TranslationLanguagePair = .defaultPair,
        yourLanguages: [String] = [],
        isSignedIn: Bool = true
    ) {
        self.defaults = defaults
        self.target = CommandHome.validTarget(target)
        self.pair = pair
        self.yourLanguages = yourLanguages
        self.isSignedIn = isSignedIn
    }

    var tilesEnabled: Bool {
        isSignedIn
    }

    var engineFieldLabel: String {
        pick == nil ? String(localized: "Engine") : String(localized: "Engine, next recording")
    }

    var engineFieldValue: String {
        pick.map(CommandHome.engineName) ?? String(localized: "As in Settings")
    }

    func engine(for action: EdgeCommandAction) -> EngineID {
        CommandHome.engine(for: action, pick: pick, defaults: defaults)
    }

    /// Picks from the Engine menu. "As in Settings" clears the pick. Returns false for a row that is not an engine.
    @discardableResult
    func pickEngine(rowID: String) -> Bool {
        if rowID == CommandHome.asInSettingsRowID {
            pick = nil
            return true
        }
        guard let engine = EngineID(rawValue: rowID) else { return false }
        pick = engine
        return true
    }

    func pickTarget(_ code: String) {
        target = CommandHome.validTarget(code)
    }

    /// A tile start: what to record with. Consumes the pick (it applies to one recording).
    func consumeStart(
        _ action: EdgeCommandAction,
        caps: (EngineID) -> EngineCapabilities?
    ) -> CommandTileStart {
        defer { pick = nil }
        return CommandHome.start(action, pick: pick, defaults: defaults, target: target, pair: pair, caps: caps)
    }

    /// Any recording start not from a tile (hotkey, menu bar) clears a pending pick (02 Q14 default).
    func clearPick() {
        pick = nil
    }

    /// The picked engine stopped being usable (key removed): back to "As in Settings" (P:411).
    func dropPickIfUnusable(_ readiness: (EngineID) -> EngineReadiness) {
        guard let pick else { return }
        switch readiness(pick) {
        case .needsKey, .unsupportedHardware, .noQuota, .unavailable: self.pick = nil
        case .ready, .signedOut, .notDownloaded: break
        }
    }

    func refresh(
        defaults: CommandHomeDefaults,
        pair: TranslationLanguagePair,
        yourLanguages: [String],
        isSignedIn: Bool
    ) {
        self.defaults = defaults
        self.pair = pair
        self.yourLanguages = yourLanguages
        self.isSignedIn = isSignedIn
    }

    func presentMeetingSuggestion(_ suggestion: MeetingSuggestion) {
        meetingSuggestion = suggestion
        meetingSuggestionsEnabled = SettingsStorage.shared.meetingSuggestionsEnabled
    }

    @discardableResult
    func selectMeetingSuggestionSegment(_ segment: MeetingSegment) -> Bool {
        guard var suggestion = meetingSuggestion, suggestion.isSelectable(segment) else { return false }
        suggestion.selectedSegment = segment
        meetingSuggestion = suggestion
        return true
    }

    @discardableResult
    func consumeMeetingSuggestionStart(id: UUID) -> MeetingSuggestion? {
        guard meetingSuggestion?.meeting.id == id else { return nil }
        defer { meetingSuggestion = nil }
        return meetingSuggestion
    }

    func dismissMeetingSuggestion(id: UUID) {
        guard meetingSuggestion?.meeting.id == id else { return }
        meetingSuggestion = nil
    }
}
