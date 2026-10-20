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
