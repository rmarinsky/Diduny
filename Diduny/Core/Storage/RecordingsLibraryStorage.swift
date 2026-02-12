import Foundation

@Observable
@MainActor
final class RecordingsLibraryStorage {
    static let shared = RecordingsLibraryStorage()

    private(set) var recordings: [Recording] = []

    private let fileManager = FileManager.default
    private let appSupportDir: URL
    private let recordingsDir: URL
    private let metadataURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "Diduny"
        let appDir = appSupport.appendingPathComponent(bundleID)
        appSupportDir = appDir

        let recDir = appDir.appendingPathComponent("Recordings")
        try? fm.createDirectory(at: recDir, withIntermediateDirectories: true)
        recordingsDir = recDir

        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        metadataURL = appDir.appendingPathComponent("recordings_metadata.json")

        loadMetadata()
        pruneOrphaned()
    }

    // MARK: - Save (from Data — voice/translation)

    func saveRecording(
        audioData: Data,
        type: Recording.RecordingType,
        duration: TimeInterval,
        transcriptionText: String? = nil
    ) {
        let id = UUID()
        let fileName = "\(id.uuidString).wav"
        let fileURL = recordingsDir.appendingPathComponent(fileName)

        do {
            try audioData.write(to: fileURL)
        } catch {
            Log.app.error("Failed to save recording audio: \(error.localizedDescription)")
            return
        }

        let status: Recording.ProcessingStatus = transcriptionText != nil ? .transcribed : .unprocessed
        let recording = Recording(
            id: id,
            createdAt: Date(),
            type: type,
            audioFileName: fileName,
            durationSeconds: duration,
            fileSizeBytes: Int64(audioData.count),
            status: status,
            transcriptionText: transcriptionText,
            processedAt: transcriptionText != nil ? Date() : nil
        )

        recordings.insert(recording, at: 0)
        saveMetadata()
        Log.app.info("Recording saved: \(type.rawValue), \(audioData.count) bytes")
    }

    // MARK: - Save (from URL — meetings, copies file)

    func saveRecording(
        audioURL: URL,
        type: Recording.RecordingType,
        duration: TimeInterval,
        transcriptionText: String? = nil
    ) {
        let id = UUID()
        let ext = audioURL.pathExtension.isEmpty ? "wav" : audioURL.pathExtension
        let fileName = "\(id.uuidString).\(ext)"
        let destURL = recordingsDir.appendingPathComponent(fileName)

        do {
            try fileManager.copyItem(at: audioURL, to: destURL)
        } catch {
            Log.app.error("Failed to copy recording file: \(error.localizedDescription)")
            return
        }

        let fileSize: Int64
        if let attrs = try? fileManager.attributesOfItem(atPath: destURL.path),
           let size = attrs[.size] as? Int64
        {
            fileSize = size
        } else {
            fileSize = 0
        }

        let status: Recording.ProcessingStatus
        if transcriptionText != nil {
            status = type == .translation ? .translated : .transcribed
        } else {
            status = .unprocessed
        }

        let recording = Recording(
            id: id,
            createdAt: Date(),
            type: type,
            audioFileName: fileName,
            durationSeconds: duration,
            fileSizeBytes: fileSize,
            status: status,
            transcriptionText: transcriptionText,
            processedAt: transcriptionText != nil ? Date() : nil
        )

        recordings.insert(recording, at: 0)
        saveMetadata()
        Log.app.info("Recording saved from file: \(type.rawValue), \(fileSize) bytes")
    }

    // MARK: - Delete

    func deleteRecording(_ recording: Recording) {
        let fileURL = recordingsDir.appendingPathComponent(recording.audioFileName)
        try? fileManager.removeItem(at: fileURL)
        recordings.removeAll { $0.id == recording.id }
        saveMetadata()
    }

    func deleteRecordings(_ ids: Set<UUID>) {
        for id in ids {
            if let recording = recordings.first(where: { $0.id == id }) {
                let fileURL = recordingsDir.appendingPathComponent(recording.audioFileName)
                try? fileManager.removeItem(at: fileURL)
            }
        }
        recordings.removeAll { ids.contains($0.id) }
        saveMetadata()
    }

    // MARK: - Update

    func updateRecording(
        id: UUID,
        status: Recording.ProcessingStatus,
        text: String? = nil,
        error: String? = nil
    ) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].status = status
        recordings[index].transcriptionText = text ?? recordings[index].transcriptionText
        recordings[index].errorMessage = error
        if status == .transcribed || status == .translated {
            recordings[index].processedAt = Date()
        }
        saveMetadata()
    }

    // MARK: - Audio File Access

    func audioFileURL(for recording: Recording) -> URL {
        recordingsDir.appendingPathComponent(recording.audioFileName)
    }

    // MARK: - Stats

    var totalSizeBytes: Int64 {
        recordings.reduce(0) { $0 + $1.fileSizeBytes }
    }

    // MARK: - Persistence

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            recordings = try decoder.decode([Recording].self, from: data)
        } catch {
            Log.app.error("Failed to load recordings metadata: \(error.localizedDescription)")
        }
    }

    private func saveMetadata() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(recordings)
            try data.write(to: metadataURL)
        } catch {
            Log.app.error("Failed to save recordings metadata: \(error.localizedDescription)")
        }
    }

    private func pruneOrphaned() {
        let before = self.recordings.count
        self.recordings.removeAll { recording in
            let fileURL = self.recordingsDir.appendingPathComponent(recording.audioFileName)
            return !self.fileManager.fileExists(atPath: fileURL.path)
        }
        if self.recordings.count != before {
            Log.app.info("Pruned \(before - self.recordings.count) orphaned recording entries")
            self.saveMetadata()
        }
    }
}
