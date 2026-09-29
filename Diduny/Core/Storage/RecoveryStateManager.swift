import AVFoundation
import Foundation

enum InterruptedWAVRecoveryError: LocalizedError {
    case invalidContainer
    case recordingTooLarge
    case noDecodableAudio

    var errorDescription: String? {
        switch self {
        case .invalidContainer:
            "The interrupted recording container is invalid."
        case .recordingTooLarge:
            "The interrupted WAV recording is too large to recover."
        case .noDecodableAudio:
            "The interrupted recording does not contain decodable audio."
        }
    }
}

enum InterruptedWAVRecovery {
    static func repairIfNeeded(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize >= 20 else { return false }
        try handle.seek(toOffset: 0)
        let containerHeader = try handle.read(upToCount: 12) ?? Data()
        guard containerHeader.count == 12,
              String(data: containerHeader.prefix(4), encoding: .ascii) == "RIFF",
              String(data: containerHeader.suffix(4), encoding: .ascii) == "WAVE"
        else { return false }

        var chunkOffset: UInt64 = 12
        while chunkOffset + 8 <= fileSize {
            try handle.seek(toOffset: chunkOffset)
            let chunkHeader = try handle.read(upToCount: 8) ?? Data()
            guard chunkHeader.count == 8 else {
                throw InterruptedWAVRecoveryError.invalidContainer
            }

            let chunkID = String(data: chunkHeader.prefix(4), encoding: .ascii)
            let declaredSize = readLittleEndianUInt32(chunkHeader, at: 4)
            if chunkID == "data" {
                let payloadOffset = chunkOffset + 8
                let payloadSize = fileSize - payloadOffset
                guard declaredSize == 0, payloadSize > 0 else { return false }
                guard payloadSize <= UInt32.max, fileSize - 8 <= UInt32.max else {
                    throw InterruptedWAVRecoveryError.recordingTooLarge
                }

                try writeLittleEndianUInt32(UInt32(fileSize - 8), at: 4, to: handle)
                try writeLittleEndianUInt32(UInt32(payloadSize), at: chunkOffset + 4, to: handle)
                try handle.synchronize()
                return true
            }

            let paddedSize = UInt64(declaredSize) + UInt64(declaredSize % 2)
            let nextOffset = chunkOffset + 8 + paddedSize
            guard nextOffset > chunkOffset, nextOffset <= fileSize else {
                throw InterruptedWAVRecoveryError.invalidContainer
            }
            chunkOffset = nextOffset
        }
        throw InterruptedWAVRecoveryError.invalidContainer
    }

    static func durationSeconds(at url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else {
            throw InterruptedWAVRecoveryError.noDecodableAudio
        }
        return TimeInterval(file.length) / sampleRate
    }

    private static func readLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset ..< offset + 4].enumerated().reduce(0) { value, byte in
            value | UInt32(byte.element) << UInt32(byte.offset * 8)
        }
    }

    private static func writeLittleEndianUInt32(
        _ value: UInt32,
        at offset: UInt64,
        to handle: FileHandle
    ) throws {
        var littleEndianValue = value.littleEndian
        let data = withUnsafeBytes(of: &littleEndianValue) { Data($0) }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }
}

enum RecoveryRecordingProcessorError: LocalizedError {
    case couldNotPersist

    var errorDescription: String? {
        "Diduny could not preserve the interrupted recording."
    }
}

@MainActor
struct RecoveryRecordingProcessor {
    struct Result {
        let recordingID: UUID
        let text: String
    }

    typealias Save = (Data, RecoveryState, TimeInterval) -> UUID?
    typealias Update = (UUID, Recording.ProcessingStatus, String?, String?) -> Void
    typealias CleanupSource = (RecoveryState) -> Void

    private let save: Save
    private let update: Update
    private let cleanupSource: CleanupSource

    init(
        save: @escaping Save,
        update: @escaping Update,
        cleanupSource: @escaping CleanupSource
    ) {
        self.save = save
        self.update = update
        self.cleanupSource = cleanupSource
    }

    func process(
        state: RecoveryState,
        transcribe: (Data, RecoveryState.RecordingType) async throws -> String
    ) async throws -> Result {
        let audioURL = URL(fileURLWithPath: state.tempFilePath)
        _ = try InterruptedWAVRecovery.repairIfNeeded(at: audioURL)
        let duration = try InterruptedWAVRecovery.durationSeconds(at: audioURL)
        let audioData = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: audioURL)
        }.value

        guard let recordingID = save(audioData, state, duration) else {
            throw RecoveryRecordingProcessorError.couldNotPersist
        }
        cleanupSource(state)
        update(recordingID, .processing, nil, nil)

        do {
            let text = try await transcribe(audioData, state.recordingType)
            let completedStatus: Recording.ProcessingStatus = switch state.recordingType {
            case .voice, .meeting:
                .transcribed
            case .translation, .meetingTranslation:
                .translated
            }
            update(recordingID, completedStatus, text, nil)
            return Result(recordingID: recordingID, text: text)
        } catch {
            update(recordingID, .failed, nil, error.localizedDescription)
            throw error
        }
    }
}

struct RecoveryState: Codable {
    let tempFilePath: String
    let startTime: Date
    let recordingType: RecordingType
    var translationTargetLanguage: String? = nil

    /// The session UUID when this state points at the chunk store used by the
    /// library recovery flow. Legacy recovery states return `nil`.
    var inProgressMeetingRecordingID: UUID? {
        guard recordingType == .meeting || recordingType == .meetingTranslation else { return nil }
        let sessionDirectory = URL(fileURLWithPath: tempFilePath).deletingLastPathComponent()
        guard sessionDirectory.deletingLastPathComponent().lastPathComponent == "InProgressRecordings" else {
            return nil
        }
        return UUID(uuidString: sessionDirectory.lastPathComponent)
    }

    enum RecordingType: String, Codable {
        case voice
        case meeting
        case translation
        case meetingTranslation

        var displayName: String {
            switch self {
            case .voice: "voice"
            case .meeting: "meeting"
            case .translation: "translation"
            case .meetingTranslation: "meeting translation"
            }
        }

        var libraryType: Recording.RecordingType {
            switch self {
            case .voice: .voice
            case .meeting: .meeting
            case .translation: .translation
            case .meetingTranslation: .meetingTranslation
            }
        }
    }
}

final class RecoveryStateManager {
    static let shared = RecoveryStateManager()

    private static let defaultFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "Diduny"
        let appDir = appSupport.appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("recovery_state.json")
    }()

    private let fileURL: URL

    private init() {
        fileURL = Self.defaultFileURL
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    @discardableResult
    func saveState(_ state: RecoveryState) -> Bool {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
            Log.app.debug("Recovery state saved: \(state.recordingType.rawValue)")
            return true
        } catch {
            Log.app.error("Failed to save recovery state: \(error.localizedDescription)")
            return false
        }
    }

    func loadState() -> RecoveryState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(RecoveryState.self, from: data)
    }

    func clearState() {
        try? FileManager.default.removeItem(at: fileURL)
        Log.app.debug("Recovery state cleared")
    }

    func makeRecordingURL() -> URL {
        let directory = fileURL.deletingLastPathComponent()
            .appendingPathComponent("RecoveryAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("diduny_\(UUID().uuidString).wav")
    }

    func hasOrphanedRecording() -> (state: RecoveryState, fileExists: Bool)? {
        guard let state = loadState() else { return nil }
        let exists = FileManager.default.fileExists(atPath: state.tempFilePath)
        return (state, exists)
    }
}
