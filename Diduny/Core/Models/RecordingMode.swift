import Foundation

enum RecordingMode: Equatable {
    case voice
    case translation(targetLanguage: String = "EN <-> UK")
    case meeting
    case meetingTranslation
    case fileTranscription

    var label: String {
        switch self {
        case .voice: String(localized: "Recording...")
        case let .translation(targetLanguage): String(localized: "Recording -> \(targetLanguage)...")
        case .meeting: String(localized: "Meeting Recording...")
        case .meetingTranslation: String(localized: "Meeting Translation...")
        case .fileTranscription: String(localized: "Transcribing File...")
        }
    }

    var processingLabel: String {
        switch self {
        case .voice: String(localized: "Processing...")
        case .translation: String(localized: "Translating...")
        case .meeting: String(localized: "Processing Meeting...")
        case .meetingTranslation: String(localized: "Translating Meeting...")
        case .fileTranscription: String(localized: "Transcribing File...")
        }
    }

    var icon: String {
        switch self {
        case .voice: "mic.fill"
        case .translation: "globe"
        case .meeting: "laptopcomputer"
        case .meetingTranslation: "captions.bubble.fill"
        case .fileTranscription: "doc.richtext.fill"
        }
    }

    var isMeeting: Bool {
        switch self {
        case .meeting, .meetingTranslation: true
        case .voice, .translation, .fileTranscription: false
        }
    }
}

/// Output picked in the live panel while a dictation or translation recording
/// runs. The realtime STT config is fixed at connect, so a different output is
/// derived from the spoken words the stream already produces instead of
/// reconnecting — the selection applies to the whole recording.
enum DictationOutput: Hashable {
    case original
    case translation(targetLanguage: String)

    enum Plan: Equatable {
        case useAsIs(String)
        case translate(String, to: String)
    }

    var targetLanguage: String? {
        if case let .translation(targetLanguage) = self { return targetLanguage }
        return nil
    }

    var label: String {
        switch self {
        case .original:
            String(localized: "Original")
        case let .translation(targetLanguage):
            SupportedLanguage.language(for: targetLanguage)?.name ?? targetLanguage.uppercased()
        }
    }

    /// Returns nil when there are no spoken words to derive from, so the
    /// caller must process the recorded audio for this output instead.
    func plan(native: DictationOutput, nativeText: String, originalText: String) -> Plan? {
        if self == native {
            return .useAsIs(nativeText)
        }
        let spoken = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return nil }
        switch self {
        case .original:
            return .useAsIs(spoken)
        case let .translation(targetLanguage):
            return .translate(spoken, to: targetLanguage)
        }
    }

    static func options(pairs: [TranslationLanguagePair], native: DictationOutput) -> [DictationOutput] {
        var options: [DictationOutput] = [.original]
        let languages = pairs.flatMap(\.codes) + [native.targetLanguage].compactMap { $0 }
        for language in languages where !options.contains(.translation(targetLanguage: language)) {
            options.append(.translation(targetLanguage: language))
        }
        return options
    }
}
