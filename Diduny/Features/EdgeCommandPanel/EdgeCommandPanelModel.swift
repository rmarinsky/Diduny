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

enum MeetingSuggestionProcessingMode: Equatable {
    case cloud
    case local
    case recordingOnly

    static func resolve(cloudEnabled: Bool, hasLocalModel: Bool) -> Self {
        if cloudEnabled { return .cloud }
        return hasLocalModel ? .local : .recordingOnly
    }

    var label: String {
        switch self {
        case .cloud: String(localized: "Cloud - live transcription")
        case .local: String(localized: "Local - transcription on this Mac")
        case .recordingOnly:
            String(localized: "Recording only - download a local model for transcription")
        }
    }

    var icon: String {
        switch self {
        case .cloud: "cloud"
        case .local: "desktopcomputer"
        case .recordingOnly: "exclamationmark.triangle"
        }
    }
}

struct MeetingSuggestion: Equatable {
    let meeting: DetectedMeeting
    var selectedProvider: TranscriptionProvider
    var isCloudAvailable: Bool
    let hasLocalModel: Bool

    var processingMode: MeetingSuggestionProcessingMode {
        .resolve(cloudEnabled: selectedProvider == .cloud, hasLocalModel: hasLocalModel)
    }

    static func resolve(
        meeting: DetectedMeeting,
        preferredProvider: TranscriptionProvider,
        cloudAvailable: Bool,
        hasLocalModel: Bool
    ) -> Self {
        Self(
            meeting: meeting,
            selectedProvider: preferredProvider == .cloud && cloudAvailable ? .cloud : .local,
            isCloudAvailable: cloudAvailable,
            hasLocalModel: hasLocalModel
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
    func selectMeetingSuggestionProvider(_ provider: TranscriptionProvider) -> Bool {
        guard var suggestion = meetingSuggestion,
              provider != .cloud || suggestion.isCloudAvailable
        else { return false }
        suggestion.selectedProvider = provider
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
