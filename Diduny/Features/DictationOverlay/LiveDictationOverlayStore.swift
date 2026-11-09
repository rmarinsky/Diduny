import Foundation
import KeyboardShortcuts
import Observation

enum LiveDictationOverlayPhase: Equatable {
    case starting
    case recording
    case finalizing
    case processing
    case pasted
    case error(String)
    case info(String)
}

@Observable
@MainActor
final class LiveDictationOverlayStore {
    /// Read by the Stop and cancel hints only; tests inject their own (test-plan T1-SH).
    @ObservationIgnored var settings: SettingsStorage = .shared
    @ObservationIgnored var hotkeys: HotkeyRegistrar = KeyboardShortcutsRegistrar.shared
    var mode: RecordingMode = .voice
    /// False while the edge panel morphs out of its tab: a static skeleton shows
    /// instead of live content, so state updates never fight the entrance.
    var contentRevealed = true
    var phase: LiveDictationOverlayPhase = .starting
    var connectionStatus: RealtimeConnectionStatus = .disconnected
    var audioLevel: Float = 0
    /// Seconds left before "Stop after silence" ends the recording; nil when not counting down.
    var silenceCountdown: Int?
    var startedAt = Date()
    /// Set when a meeting is stopped; the timer shows the recorded length instead of counting.
    var endedAt: Date?
    /// Box text while the "Transcribing in background" hand-off is shown; nil otherwise.
    var backgroundHandoffDetail: String?
    var finalText = ""
    var provisionalText = ""
    var copiedAt: Date?
    /// Set while a meeting records audio only; turns on the cloud live transcript.
    var onTurnOnLiveTranscript: (() -> Void)?
    /// Meeting panel segment and engine per segment (WP-31). Seeded from Settings > Modes once WP-13 lands.
    var meetingSegment: MeetingSegment = .cloud
    var meetingEngines: [MeetingSegment: EngineID] = MeetingPanelState.defaultEngines
    /// Until WP-63 moves audio mid-meeting, the panel shows the running segment and engine and
    /// offers no switch: a pick that only changed the label would misreport where audio goes.
    var meetingSwitchingLocked = true
    /// What the live STT stream produces for this session.
    private(set) var nativeOutput: DictationOutput = .original
    /// Output of the session or picked in the panel, before any spoken command.
    private(set) var pickedOutput: DictationOutput = .original
    /// "Translate into X" said as the first or last final words.
    private(set) var voiceCommand: VoiceTranslationCommand?
    /// Off after Undo or a manual pick, and when voice commands are off or unavailable.
    private(set) var listensForVoiceCommands = false
    /// Output for the whole recording at Stop.
    var selectedOutput: DictationOutput {
        voiceCommand?.output ?? pickedOutput
    }
    /// Empty hides the output picker.
    private(set) var outputOptions: [DictationOutput] = []
    /// Latest text-translated preview of the spoken words.
    var convertedPreview: (output: DictationOutput, source: String, text: String)?

    private var fallbackFinalText = ""
    private var fallbackProvisionalText = ""
    /// Meeting turns behind `MeetingLiveContent` (WP-31).
    let meetingTranscript = LiveTranscriptStore()
    /// Translate meeting: the session's pair, engine and two-way transcript (WP-32).
    var meetingTranslationPair = TranslationLanguagePair(languageA: "en", languageB: "uk")
    var meetingTranslationEngine: EngineID = .didunyCloud
    var meetingTranslation = TranslateMeetingTranscript(pair: TranslationLanguagePair(languageA: "en", languageB: "uk"))
    var meetingTranslationShowsOriginal = false
    /// Battery warning on This Mac (WP-16, WP-31).
    @ObservationIgnored private(set) lazy var powerSource = PowerSourceMonitor()

    var title: String {
        panelState.title
    }

    /// Engine of the running session (N6, N18); nil until the controller sets it at start.
    var sessionEngine: LiveSessionEngine?
    /// Settings > Languages, first in the Output menu.
    var yourLanguages: [String] = YourLanguages.defaultCodes

    /// What the live panel shows now.
    var panelState: LivePanelState {
        LivePanelState(
            mode: mode,
            phase: phase,
            connectionStatus: connectionStatus,
            engine: sessionEngine,
            output: mode.isMeeting ? .original : displayedOutput,
            hasText: hasText
        )
    }

    /// The Output the title and caption follow: the picked output, or the session's own target.
    private var displayedOutput: DictationOutput {
        if !outputOptions.isEmpty { return selectedOutput }
        if case let .translation(target) = mode { return .translation(targetLanguage: target) }
        return .original
    }

    /// Output menu: Original, your languages, all languages (01 §4 item 3).
    var outputMenu: PickerMenuModel {
        DictationOutputMenu.model(yourLanguages: yourLanguages, selected: selectedOutput)
    }

    var visibleText: String {
        // The pasted result replaces the live text once processing completes.
        guard selectedOutput != nativeOutput, phase != .pasted else { return bestText(includeProvisional: true) }
        if selectedOutput == .original {
            return spokenText
        }
        guard let convertedPreview, convertedPreview.output == selectedOutput else { return spokenText }
        return convertedPreview.text
    }

    /// Spoken words still waiting for a text-translated preview, or nil when
    /// the stream already produces the selected output.
    var outputSourceText: String? {
        guard selectedOutput != nativeOutput, selectedOutput != .original else { return nil }
        let text = voiceCommand?.remainingText ?? spokenText
        return text.isEmpty ? nil : text
    }

    /// True while the panel shows the text-translated preview instead of the spoken words.
    var isShowingConvertedPreview: Bool {
        phase != .pasted && selectedOutput != nativeOutput && selectedOutput != .original
            && convertedPreview?.output == selectedOutput
    }

    private var spokenFinalText: String {
        (nativeOutput == .original ? finalText : fallbackFinalText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var spokenText: String {
        nativeOutput == .original
            ? bestText(includeProvisional: true)
            : composedText(final: fallbackFinalText, provisional: fallbackProvisionalText)
    }

    var displayText: String {
        guard mode == .meeting else { return visibleText }
        let structuredText = meetingTranscript.finalTranscriptText
        guard !structuredText.isEmpty else { return visibleText }

        let provisional = meetingTranscript.provisionalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provisional.isEmpty else { return structuredText }

        let speaker = meetingTranscript.provisionalSpeaker.map { "Speaker \($0): " } ?? ""
        return "\(structuredText)\n\n\(speaker)\(provisional)"
    }

    var hasText: Bool {
        !displayText.isEmpty
    }

    var canStop: Bool {
        phase == .recording || phase == .starting
    }

    var stopShortcutHint: String? {
        guard canStop else { return nil }

        switch mode {
        case .voice:
            if let modifierHint = modifierToggleHint(
                key: settings.pushToTalkKey,
                isEnabled: settings.pushToTalkToggleEnabled,
                tapCount: settings.pushToTalkToggleTapCount
            ) {
                return modifierHint
            }
            return actionShortcutHint(.toggleRecording, pressCount: 1)
        case .translation:
            if let modifierHint = modifierToggleHint(
                key: settings.translationPushToTalkKey,
                isEnabled: settings.translationPushToTalkToggleEnabled,
                tapCount: settings.translationPushToTalkToggleTapCount
            ) {
                return modifierHint
            }
            return actionShortcutHint(
                .toggleTranslation,
                pressCount: 1
            )
        case .meeting:
            return actionShortcutHint(
                .toggleMeetingRecording,
                pressCount: 1
            )
        case .meetingTranslation:
            return actionShortcutHint(
                .toggleMeetingTranslation,
                pressCount: 1
            )
        case .fileTranscription:
            return nil
        }
    }

    var cancelShortcutHint: String? {
        guard canStop, settings.escapeCancelEnabled else { return nil }
        return repeatedShortcutHint(
            settings.escapeCancelShortcut.displayName,
            pressCount: settings.escapeCancelPressCount
        )
    }

    func reset(mode: RecordingMode) {
        self.mode = mode
        phase = .starting
        connectionStatus = .disconnected
        audioLevel = 0
        startedAt = Date()
        endedAt = nil
        backgroundHandoffDetail = nil
        finalText = ""
        provisionalText = ""
        fallbackFinalText = ""
        fallbackProvisionalText = ""
        meetingTranscript.reset()
        applyMeetingDefaults()
        copiedAt = nil
        nativeOutput = .original
        pickedOutput = .original
        voiceCommand = nil
        listensForVoiceCommands = false
        outputOptions = []
        convertedPreview = nil
        onTurnOnLiveTranscript = nil
        sessionEngine = nil
    }

    func configureOutput(native: DictationOutput, options: [DictationOutput], listensForVoiceCommands: Bool) {
        nativeOutput = native
        pickedOutput = native
        voiceCommand = nil
        self.listensForVoiceCommands = listensForVoiceCommands
        outputOptions = options
        convertedPreview = nil
    }

    /// A manual pick, or Undo, wins over spoken commands for the rest of the recording.
    func pickOutput(_ output: DictationOutput) {
        pickedOutput = output
        voiceCommand = nil
        listensForVoiceCommands = false
    }

    /// Re-checks the start and end of the final words for a spoken command.
    func updateVoiceCommand() {
        guard listensForVoiceCommands else { return }
        applyVoiceCommand(VoiceTranslationCommand.detect(
            in: spokenFinalText,
            position: SettingsStorage.shared.voiceTranslationCommandPosition,
            languages: SettingsStorage.shared.voiceTranslationCommandLanguages
        ))
    }

    func applyVoiceCommand(_ command: VoiceTranslationCommand?) {
        guard listensForVoiceCommands, command != voiceCommand else { return }
        voiceCommand = command
    }

    func processTokens(_ tokens: [RealtimeToken]) {
        if mode == .meeting {
            meetingTranscript.processTokens(tokens)
        } else if mode == .meetingTranslation {
            meetingTranslation.process(tokens)
        }

        let isTranslationMode = switch mode {
        case .translation, .meetingTranslation:
            true
        case .voice, .meeting, .fileTranscription:
            false
        }

        var provisionalPrimary = ""
        var provisionalFallback = ""

        for token in tokens where !token.text.isEmpty {
            if token.isFinal {
                if isTranslationMode {
                    if token.isTranslationOutput {
                        finalText += token.text
                    } else {
                        fallbackFinalText += token.text
                    }
                } else {
                    finalText += token.text
                }
                continue
            }

            if isTranslationMode {
                if token.isTranslationOutput {
                    provisionalPrimary += token.text
                } else {
                    provisionalFallback += token.text
                }
            } else {
                provisionalPrimary += token.text
            }
        }

        if !provisionalPrimary.isEmpty || !provisionalFallback.isEmpty {
            provisionalText = provisionalPrimary
            fallbackProvisionalText = provisionalFallback
        } else if tokens.contains(where: \.isFinal) {
            provisionalText = ""
            fallbackProvisionalText = ""
        }
    }

    func markSegmentBoundary() {
        guard mode == .meeting else { return }
        meetingTranscript.markSegmentBoundary()
    }

    func bestText(includeProvisional: Bool) -> String {
        let primary = composedText(final: finalText, provisional: includeProvisional ? provisionalText : "")
        if !primary.isEmpty {
            return primary
        }

        return composedText(
            final: fallbackFinalText,
            provisional: includeProvisional ? fallbackProvisionalText : ""
        )
    }

    func markCopied() {
        copiedAt = Date()
    }

    private func composedText(final: String, provisional: String) -> String {
        (final + provisional).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func modifierToggleHint(key: PushToTalkKey, isEnabled: Bool, tapCount: Int) -> String? {
        guard isEnabled, key != .none else { return nil }
        return repeatedShortcutHint(key.symbol, pressCount: tapCount)
    }

    private func actionShortcutHint(_ name: KeyboardShortcuts.Name, pressCount: Int) -> String? {
        guard let shortcut = hotkeys.getShortcut(for: name) else { return nil }
        return repeatedShortcutHint(String(describing: shortcut), pressCount: pressCount)
    }

    private func repeatedShortcutHint(_ shortcut: String, pressCount: Int) -> String {
        pressCount > 1 ? "\(shortcut) ×\(pressCount)" : shortcut
    }
}
