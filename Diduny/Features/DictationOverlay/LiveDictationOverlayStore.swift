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
    var mode: RecordingMode = .voice
    var phase: LiveDictationOverlayPhase = .starting
    var connectionStatus: RealtimeConnectionStatus = .disconnected
    var audioLevel: Float = 0
    var startedAt = Date()
    var finalText = ""
    var provisionalText = ""
    var copiedAt: Date?
    /// Set while a meeting records audio only; turns on the cloud live transcript.
    var onTurnOnLiveTranscript: (() -> Void)?
    /// What the live STT stream produces for this session.
    private(set) var nativeOutput: DictationOutput = .original
    /// Output picked in the panel; applies to the whole recording at Stop.
    var selectedOutput: DictationOutput = .original
    /// Empty hides the output picker.
    private(set) var outputOptions: [DictationOutput] = []
    /// Latest text-translated preview of the spoken words.
    var convertedPreview: (output: DictationOutput, source: String, text: String)?

    private var fallbackFinalText = ""
    private var fallbackProvisionalText = ""
    private let meetingTranscript = LiveTranscriptStore()

    var title: String {
        if !outputOptions.isEmpty {
            return selectedOutput == .original
                ? String(localized: "Transcribing")
                : String(localized: "Translating")
        }
        return switch mode {
        case .voice:
            String(localized: "Transcribing")
        case .translation:
            String(localized: "Translating")
        case .meeting:
            String(localized: "Recording meeting")
        case .meetingTranslation:
            String(localized: "Translating meeting")
        case .fileTranscription:
            String(localized: "File Transcription")
        }
    }

    var statusText: String {
        switch phase {
        case .starting:
            String(localized: "Starting")
        case .recording:
            switch connectionStatus {
            case .connected:
                String(localized: "Recording live")
            case .connecting:
                String(localized: "Connecting")
            case .reconnecting:
                String(localized: "Reconnecting")
            case .failed:
                String(localized: "Recording offline")
            case .disconnected:
                String(localized: "Recording")
            }
        case .finalizing:
            String(localized: "Finalizing")
        case .processing:
            String(localized: "Formatting")
        case .pasted:
            String(localized: "Complete")
        case let .error(message):
            message
        case let .info(message):
            message
        }
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
        let text = spokenText
        return text.isEmpty ? nil : text
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
                key: SettingsStorage.shared.pushToTalkKey,
                isEnabled: SettingsStorage.shared.pushToTalkToggleEnabled,
                tapCount: SettingsStorage.shared.pushToTalkToggleTapCount
            ) {
                return modifierHint
            }
            return actionShortcutHint(.toggleRecording, pressCount: SettingsStorage.shared.recordingHotkeyPressCount)
        case .translation:
            if let modifierHint = modifierToggleHint(
                key: SettingsStorage.shared.translationPushToTalkKey,
                isEnabled: SettingsStorage.shared.translationPushToTalkToggleEnabled,
                tapCount: SettingsStorage.shared.translationPushToTalkToggleTapCount
            ) {
                return modifierHint
            }
            return actionShortcutHint(
                .toggleTranslation,
                pressCount: SettingsStorage.shared.translationHotkeyPressCount
            )
        case .meeting:
            return actionShortcutHint(
                .toggleMeetingRecording,
                pressCount: SettingsStorage.shared.meetingHotkeyPressCount
            )
        case .meetingTranslation:
            return actionShortcutHint(
                .toggleMeetingTranslation,
                pressCount: SettingsStorage.shared.meetingTranslationHotkeyPressCount
            )
        case .fileTranscription:
            return nil
        }
    }

    var cancelShortcutHint: String? {
        guard canStop, SettingsStorage.shared.escapeCancelEnabled else { return nil }
        return repeatedShortcutHint(
            "Esc",
            pressCount: SettingsStorage.shared.escapeCancelPressCount
        )
    }

    var providerLabel: String {
        let provider: TranscriptionProvider = switch mode {
        case .translation, .meetingTranslation:
            SettingsStorage.shared.effectiveTranslationProvider
        case .voice, .meeting, .fileTranscription:
            SettingsStorage.shared.effectiveTranscriptionProvider
        }
        return provider == .cloud ? "Cloud" : "Local"
    }

    var sourceLabel: String {
        mode.isMeeting ? String(localized: "System + microphone") : "Microphone"
    }

    var targetLabel: String? {
        if !outputOptions.isEmpty {
            return selectedOutput.targetLanguage.map { _ in selectedOutput.label }
        }
        return switch mode {
        case let .translation(targetLanguage):
            targetLanguage
        case .meetingTranslation:
            SettingsStorage.shared.resolveTranslationLanguagePair().displayLabel
        case .voice, .meeting, .fileTranscription:
            nil
        }
    }

    func reset(mode: RecordingMode) {
        self.mode = mode
        phase = .starting
        connectionStatus = .disconnected
        audioLevel = 0
        startedAt = Date()
        finalText = ""
        provisionalText = ""
        fallbackFinalText = ""
        fallbackProvisionalText = ""
        meetingTranscript.reset()
        copiedAt = nil
        nativeOutput = .original
        selectedOutput = .original
        outputOptions = []
        convertedPreview = nil
        onTurnOnLiveTranscript = nil
    }

    func configureOutput(native: DictationOutput, options: [DictationOutput]) {
        nativeOutput = native
        selectedOutput = native
        outputOptions = options
        convertedPreview = nil
    }

    func processTokens(_ tokens: [RealtimeToken]) {
        if mode == .meeting {
            meetingTranscript.processTokens(tokens)
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
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return nil }
        return repeatedShortcutHint(String(describing: shortcut), pressCount: pressCount)
    }

    private func repeatedShortcutHint(_ shortcut: String, pressCount: Int) -> String {
        pressCount > 1 ? "\(shortcut) ×\(pressCount)" : shortcut
    }
}
