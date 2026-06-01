import Foundation

/// On-disk manifest for a single in-progress recording session.
/// Matches ADR-0009 §D2 schema. For M1 `chunks` has at most one entry;
/// M3 will rotate and append additional entries.
struct InProgressRecordingManifest: Codable, Sendable {
    let id: UUID
    /// Schema version for forward-compat reads. Current: 1.
    let schemaVersion: Int
    let type: RecordingTypeKind
    let startedAt: Date
    let sourceDevice: SourceDeviceInfo?
    let audioConfig: AudioConfig
    var chunks: [ChunkEntry]
    var lastWriteAt: Date
    /// Set to true when the recording was interrupted by macOS sleep (M2 will flip this).
    /// M1 always writes `false`.
    var recordingInterruptedBySleep: Bool

    enum RecordingTypeKind: String, Codable, Sendable {
        case voice
        case meeting
        case translation
        case meetingTranslation
    }

    struct SourceDeviceInfo: Codable, Sendable {
        let uid: String
        let name: String
        let transportType: String
        let sampleRate: Double
        let channelCount: Int
        let wasDefaultRoute: Bool
    }

    struct AudioConfig: Codable, Sendable {
        let sampleRate: Double
        let channels: Int
        let bitDepth: Int
    }

    struct ChunkEntry: Codable, Sendable {
        let index: Int
        let filename: String
        var byteCount: Int64
        var durationSeconds: Double
        /// nil means the chunk did not close cleanly (writer crashed or was killed mid-write).
        var closedAt: Date?
    }
}
