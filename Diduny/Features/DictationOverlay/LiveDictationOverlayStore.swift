import Foundation
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

    private var fallbackFinalText = ""
    private var fallbackProvisionalText = ""

    var title: String {
        switch mode {
        case .voice:
            "Dictation"
        case .translation:
            "Translation"
        case .meeting:
            "Meeting"
        case .meetingTranslation:
            "Meeting Translation"
        case .fileTranscription:
            "File Transcription"
        }
    }

    var statusText: String {
        switch phase {
        case .starting:
            "Starting"
        case .recording:
            switch connectionStatus {
            case .connected:
                "Recording live"
            case .connecting:
                "Connecting"
            case .reconnecting:
                "Reconnecting"
            case .failed:
                "Recording offline"
            case .disconnected:
                "Recording"
            }
        case .finalizing:
            "Finalizing"
        case .processing:
            "Formatting"
        case .pasted:
            "Pasted"
        case let .error(message):
            message
        case let .info(message):
            message
        }
    }

    var visibleText: String {
        bestText(includeProvisional: true)
    }

    var hasText: Bool {
        !visibleText.isEmpty
    }

    var canStop: Bool {
        phase == .recording || phase == .starting
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
        copiedAt = nil
    }

    func processTokens(_ tokens: [RealtimeToken]) {
        let isTranslationMode: Bool = {
            if case .translation = mode { return true }
            return false
        }()

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
        } else if tokens.contains(where: { $0.isFinal }) {
            provisionalText = ""
            fallbackProvisionalText = ""
        }
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
}

private extension RealtimeToken {
    var isTranslationOutput: Bool {
        switch translationStatus?.lowercased() {
        case "translation", "translated", "target":
            true
        default:
            false
        }
    }
}
