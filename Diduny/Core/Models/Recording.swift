import Foundation

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

    // Nested to avoid conflict with RecoveryState.RecordingType
    enum RecordingType: String, Codable, CaseIterable {
        case voice
        case translation
        case meeting

        var displayName: String {
            switch self {
            case .voice: "Voice"
            case .translation: "Translation"
            case .meeting: "Meeting"
            }
        }

        var iconName: String {
            switch self {
            case .voice: "mic.fill"
            case .translation: "globe"
            case .meeting: "person.3.fill"
            }
        }
    }

    enum ProcessingStatus: String, Codable {
        case unprocessed
        case processing
        case transcribed
        case translated
        case failed

        var displayName: String {
            switch self {
            case .unprocessed: "Unprocessed"
            case .processing: "Processing"
            case .transcribed: "Transcribed"
            case .translated: "Translated"
            case .failed: "Failed"
            }
        }
    }
}
