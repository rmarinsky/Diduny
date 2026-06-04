import Foundation

struct RecordingDeviceInfo: Codable, Equatable {
    let uid: String
    let name: String
    let transportType: String
    let sampleRate: Double
    let channelCount: Int
    let wasDefaultRoute: Bool
}

/// Describes how a recording entered the library via a non-normal stop path.
/// `nil` on `Recording.recoverySource` means the recording was stopped normally.
enum RecoverySource: String, Codable, Sendable {
    /// The recording was assembled from an orphaned in-progress session directory
    /// (e.g. after a crash, force-quit, or sleep interruption).
    case orphanedSession
    // Future cases: .importedFile, .crashRecovery — out of scope for M0.
}

struct Recording: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let type: RecordingType
    let audioFileName: String
    let durationSeconds: TimeInterval
    let fileSizeBytes: Int64
    var status: ProcessingStatus
    var transcriptionText: String?
    var errorMessage: String?
    var processedAt: Date?
    var chapters: [MeetingChapter]?
    let sourceDevice: RecordingDeviceInfo?
    /// Marks a recording that originated from a recovery path rather than a normal
    /// stop; intended to drive the "Recovered" badge in the library and the
    /// detail-view notice. Once set it is preserved (never cleared), including
    /// across `RecordingsLibraryStorage.replaceStoredAudioFile`.
    ///
    /// NOTE: no production save path sets this yet — `saveRecording(...)` doesn't
    /// accept it and `recoverRecording(from:)` transcribes then discards without
    /// creating a library entry. So in practice this is currently always nil.
    /// TODO: populate it when the recovery-save-to-library flow is implemented.
    var recoverySource: RecoverySource?

    /// Nested to avoid conflict with RecoveryState.RecordingType
    enum RecordingType: String, Codable, CaseIterable {
        case voice
        case translation
        case meeting
        case fileTranscription

        var displayName: String {
            switch self {
            case .voice: "Voice"
            case .translation: "Translation"
            case .meeting: "Meeting"
            case .fileTranscription: "File Transcription"
            }
        }

        var iconName: String {
            switch self {
            case .voice: "mic.fill"
            case .translation: "globe"
            case .meeting: "person.3.fill"
            case .fileTranscription: "doc.fill"
            }
        }

        var shortPrefix: String {
            switch self {
            case .voice: "Transcribe"
            case .translation: "Translate"
            case .meeting: "Meeting"
            case .fileTranscription: "File"
            }
        }

        var clipboardCopyBehavior: ClipboardCopyBehavior {
            switch self {
            case .voice, .translation, .fileTranscription:
                .cleaned
            case .meeting:
                .raw
            }
        }
    }

    enum ProcessingStatus: String, Codable {
        case unprocessed
        case processing
        case transcribed
        case translated
        case failed
        /// Audio was recovered from an interrupted session and one or more chunks
        /// were unreadable. The reported duration reflects only the intact chunks.
        case partiallyRecovered

        var displayName: String {
            switch self {
            case .unprocessed: "Unprocessed"
            case .processing: "Processing"
            case .transcribed: "Transcribed"
            case .translated: "Translated"
            case .failed: "Failed"
            case .partiallyRecovered: "Partially Recovered"
            }
        }
    }
}
