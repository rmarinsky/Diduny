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
        id: UUID? = nil,
        audioData: Data,
        type: Recording.RecordingType,
        duration: TimeInterval,
        transcriptionText: String? = nil,
        sourceDevice: RecordingDeviceInfo? = nil
    ) {
        let recordingID = id ?? UUID()
        let fileExtension = detectedAudioFileExtension(for: audioData)
        let fileName = "\(recordingID.uuidString).\(fileExtension)"
        let fileURL = recordingsDir.appendingPathComponent(fileName)

        do {
            try audioData.write(to: fileURL)
        } catch {
            Log.app.error("Failed to save recording audio: \(error.localizedDescription)")
            return
        }

        let status: Recording.ProcessingStatus = if transcriptionText != nil {
            type == .translation ? .translated : .transcribed
        } else {
            .unprocessed
        }
        let recording = Recording(
            id: recordingID,
            createdAt: Date(),
            type: type,
            audioFileName: fileName,
            durationSeconds: duration,
            fileSizeBytes: Int64(audioData.count),
            status: status,
            transcriptionText: transcriptionText,
            processedAt: transcriptionText != nil ? Date() : nil,
            sourceDevice: sourceDevice
        )

        recordings.insert(recording, at: 0)
        saveMetadata()
        Log.app.info("Recording saved: \(type.rawValue), \(audioData.count) bytes")
    }

    // MARK: - Save (from URL — meetings, copies file)

    func saveRecording(
        id: UUID? = nil,
        audioURL: URL,
        type: Recording.RecordingType,
        duration: TimeInterval,
        transcriptionText: String? = nil,
        sourceDevice: RecordingDeviceInfo? = nil
    ) {
        let recordingID = id ?? UUID()
        let ext = audioURL.pathExtension.isEmpty ? "wav" : audioURL.pathExtension
        let fileName = "\(recordingID.uuidString).\(ext)"
        let destURL = recordingsDir.appendingPathComponent(fileName)

        do {
            try fileManager.copyItem(at: audioURL, to: destURL)
        } catch {
            Log.app.error("Failed to copy recording file: \(error.localizedDescription)")
            return
        }

        let fileSize: Int64 = if let attrs = try? fileManager.attributesOfItem(atPath: destURL.path),
                                 let size = attrs[.size] as? Int64
        {
            size
        } else {
            0
        }

        let status: Recording.ProcessingStatus = if transcriptionText != nil {
            type == .translation ? .translated : .transcribed
        } else {
            .unprocessed
        }

        let recording = Recording(
            id: recordingID,
            createdAt: Date(),
            type: type,
            audioFileName: fileName,
            durationSeconds: duration,
            fileSizeBytes: fileSize,
            status: status,
            transcriptionText: transcriptionText,
            processedAt: transcriptionText != nil ? Date() : nil,
            sourceDevice: sourceDevice
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

    func optimizeStoredRecordingIfNeeded(id: UUID) async -> URL? {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return nil }

        let recording = recordings[index]
        let sourceURL = audioFileURL(for: recording)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }

        let detectedExtension = detectedAudioFileExtension(for: sourceURL)

        if detectedExtension == "flac", sourceURL.pathExtension.lowercased() != "flac" {
            let normalizedURL = sourceURL.deletingPathExtension().appendingPathExtension("flac")
            return replaceStoredAudioFile(
                at: index,
                from: sourceURL,
                to: normalizedURL,
                moveOnly: true
            )
        }

        guard detectedExtension == "wav" else {
            return sourceURL
        }

        let compressedURL = await AudioCompressionService.compressToFLAC(wavURL: sourceURL)
        guard compressedURL != sourceURL else {
            return sourceURL
        }

        return replaceStoredAudioFile(
            at: index,
            from: sourceURL,
            to: compressedURL,
            moveOnly: false
        )
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
        let before = recordings.count
        let recordingsDir = self.recordingsDir
        let fileManager = self.fileManager
        recordings.removeAll { recording in
            let fileURL = recordingsDir.appendingPathComponent(recording.audioFileName)
            return !fileManager.fileExists(atPath: fileURL.path)
        }
        if recordings.count != before {
            let prunedCount = before - recordings.count
            Log.app.info("Pruned \(prunedCount) orphaned recording entries")
            saveMetadata()
        }
    }

    private func replaceStoredAudioFile(
        at index: Int,
        from sourceURL: URL,
        to replacementURL: URL,
        moveOnly: Bool
    ) -> URL {
        let recording = recordings[index]
        let replacementFileName = replacementURL.lastPathComponent
        let replacementFileSize: Int64 = if let attrs = try? fileManager.attributesOfItem(atPath: replacementURL.path),
                                            let size = attrs[.size] as? Int64
        {
            size
        } else {
            recording.fileSizeBytes
        }

        do {
            if moveOnly {
                try fileManager.moveItem(at: sourceURL, to: replacementURL)
            } else {
                try fileManager.removeItem(at: sourceURL)
            }

            recordings[index] = Recording(
                id: recording.id,
                createdAt: recording.createdAt,
                type: recording.type,
                audioFileName: replacementFileName,
                durationSeconds: recording.durationSeconds,
                fileSizeBytes: replacementFileSize,
                status: recording.status,
                transcriptionText: recording.transcriptionText,
                errorMessage: recording.errorMessage,
                processedAt: recording.processedAt,
                chapters: recording.chapters,
                sourceDevice: recording.sourceDevice
            )
            saveMetadata()

            Log.app.info(
                "Recording storage optimized: \(recording.audioFileName) → \(replacementFileName), \(recording.fileSizeBytes) → \(replacementFileSize) bytes"
            )
            return replacementURL
        } catch {
            Log.app.warning("Failed to replace stored recording audio: \(error.localizedDescription)")
            if !moveOnly {
                try? fileManager.removeItem(at: replacementURL)
            }
            return sourceURL
        }
    }

    private func detectedAudioFileExtension(for audioData: Data) -> String {
        if audioData.count >= 4, String(data: audioData.prefix(4), encoding: .ascii) == "fLaC" {
            return "flac"
        }

        if audioData.count >= 12,
           String(data: audioData.prefix(4), encoding: .ascii) == "RIFF",
           String(data: audioData.dropFirst(8).prefix(4), encoding: .ascii) == "WAVE"
        {
            return "wav"
        }

        return "wav"
    }

    private func detectedAudioFileExtension(for fileURL: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return fileURL.pathExtension.lowercased()
        }
        defer { try? handle.close() }

        let header = (try? handle.read(upToCount: 12)) ?? Data()
        return detectedAudioFileExtension(for: header)
    }
}
