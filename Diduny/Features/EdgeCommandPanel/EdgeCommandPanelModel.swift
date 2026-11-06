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
