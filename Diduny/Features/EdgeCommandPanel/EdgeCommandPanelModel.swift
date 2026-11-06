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
        case .transcribe: "waveform"
        case .translate: "character.bubble"
        case .meeting: "record.circle"
        case .translateMeeting: "captions.bubble"
        case .batch: "tray.full"
        }
    }

    var usesLanguagePair: Bool {
        self == .translate || self == .translateMeeting
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

    /// Today's start path only knows Cloud or Local; Record only records on this Mac.
    var legacyProvider: TranscriptionProvider {
        segment == .cloud ? .cloud : .local
    }
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
    var pairs: [TranslationLanguagePair]
    var selectedPairID: String
    var provider: TranscriptionProvider
    var isSignedIn: Bool
    var isExpanded = false
    var isShowingLiveFeedback = false
    /// Live recording is active but the user collapsed the panel to the edge tab.
    var isLiveFeedbackMinimized = false
    var meetingSuggestion: MeetingSuggestion?
    var meetingSuggestionsEnabled = SettingsStorage.shared.meetingSuggestionsEnabled
    var dockEdge: EdgeCommandPanelDockEdge = .right

    init(
        pairs: [TranslationLanguagePair],
        selectedPair: TranslationLanguagePair,
        provider: TranscriptionProvider = .local,
        isSignedIn: Bool = true
    ) {
        let normalizedPairs = pairs.isEmpty ? [.defaultPair] : pairs
        self.pairs = normalizedPairs
        self.provider = provider
        self.isSignedIn = isSignedIn
        selectedPairID = normalizedPairs.contains(selectedPair) ? selectedPair.id : normalizedPairs[0].id
    }

    var availableActions: [EdgeCommandAction] {
        if provider == .cloud {
            return [.transcribe, .translate, .meeting, .translateMeeting]
        }
        return [.transcribe, .meeting]
    }

    var showsTranslationControls: Bool {
        provider == .cloud
    }

    var selectedPair: TranslationLanguagePair? {
        pairs.first(where: { $0.id == selectedPairID }) ?? pairs.first
    }

    func select(_ pair: TranslationLanguagePair) {
        guard pairs.contains(pair) else { return }
        selectedPairID = pair.id
    }

    @discardableResult
    func selectProvider(_ provider: TranscriptionProvider) -> Bool {
        guard provider != .cloud || isSignedIn else { return false }
        self.provider = provider
        return true
    }

    func refresh(
        pairs: [TranslationLanguagePair],
        selectedPair: TranslationLanguagePair,
        provider: TranscriptionProvider? = nil,
        isSignedIn: Bool? = nil
    ) {
        self.pairs = pairs.isEmpty ? [.defaultPair] : pairs
        selectedPairID = self.pairs.contains(selectedPair) ? selectedPair.id : self.pairs[0].id
        if let provider {
            self.provider = provider
        }
        if let isSignedIn {
            self.isSignedIn = isSignedIn
        }
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
