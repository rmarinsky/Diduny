import Foundation

/// Stitches in-progress meeting chunks and attaches them to the live library row.
@MainActor
final class MeetingRecoveryService {
    static let shared = MeetingRecoveryService()

    private let storage: RecordingsLibraryStorage
    private let inProgressStore: InProgressRecordingStore?

    private init() {
        storage = .shared
        inProgressStore = try? InProgressRecordingStore.sharedStore()
    }

    init(
        storage: RecordingsLibraryStorage,
        inProgressStore: InProgressRecordingStore
    ) {
        self.storage = storage
        self.inProgressStore = inProgressStore
    }

    enum RecoveryAction {
        case processNow
        case saveAudioOnly
        case discard
    }

    private var inFlightRecordingIDs: Set<UUID> = []

    /// Finalizes a `.needsRecovery` (or still-orphaned in-progress) meeting into the library.
    /// Guards against concurrent calls for the same `recordingID` (e.g. a double-clicked
    /// action button), which would otherwise race two stitches against the same
    /// in-progress directory.
    @discardableResult
    func resolve(
        recordingID: UUID,
        action: RecoveryAction
    ) async -> Bool {
        guard inFlightRecordingIDs.insert(recordingID).inserted else {
            Log.app.info("Meeting recovery already in progress for \(recordingID.uuidString), ignoring duplicate request")
            return false
        }
        defer { inFlightRecordingIDs.remove(recordingID) }

        switch action {
        case .discard:
            if let recording = storage.recordings.first(where: { $0.id == recordingID }),
               !storage.deleteRecording(recording)
            {
                return false
            }
            await cleanupInProgress(recordingID)
            return true

        case .saveAudioOnly, .processNow:
            guard let stitched = await stitchInProgressAudio(for: recordingID) else {
                reportFailure(recordingID)
                return false
            }

            let recording = storage.recordings.first(where: { $0.id == recordingID })
            let createdAt = recording?.createdAt ?? Date()
            let endedAt = recording?.endedAt ?? Date()
            let duration = stitched.durationSeconds > 0
                ? stitched.durationSeconds
                : max(0, endedAt.timeIntervalSince(createdAt))

            let status: Recording.ProcessingStatus = action == .processNow ? .processing : .unprocessed
            let ok = storage.finalizeInProgressRecording(
                id: recordingID,
                audioURL: stitched.url,
                duration: duration,
                endedAt: endedAt,
                status: status,
                recoverySource: .orphanedSession,
                forceSave: true
            )
            guard ok else {
                reportFailure(recordingID)
                return false
            }

            await storage.attachInProgressTracks(from: recordingID, to: recordingID)
            await cleanupInProgress(recordingID)

            if action == .processNow {
                let queueAction: RecordingQueueService.QueueAction =
                    recording?.type == .meetingTranslation ? .translate : .transcribeDiarize
                RecordingQueueService.shared.enqueue([recordingID], action: queueAction)
            }
            return true
        }
    }

    /// Stays on the row and in the detail, so a failed attempt is never silent.
    private func reportFailure(_ recordingID: UUID) {
        storage.updateStatusDetail(
            id: recordingID,
            detail: String(localized: "Could not recover meeting audio")
        )
    }

    private struct StitchOutput {
        let url: URL
        let durationSeconds: TimeInterval
    }

    private func stitchInProgressAudio(for recordingID: UUID) async -> StitchOutput? {
        do {
            guard let store = inProgressStore else { return nil }
            let dir = try await store.directoryURL(for: recordingID)
            let manifest = try await store.readManifest(for: recordingID)

            var chunkURLs: [URL] = []
            if let manifest {
                chunkURLs = manifest.chunks
                    .sorted { $0.index < $1.index }
                    .map { dir.appendingPathComponent($0.filename) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
            }

            if chunkURLs.isEmpty {
                // Fall back to any chunk_*.wav present on disk.
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil
                )) ?? []
                chunkURLs = contents
                    .filter { $0.lastPathComponent.hasPrefix("chunk_") && $0.pathExtension == "wav" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }

            guard !chunkURLs.isEmpty else { return nil }

            let target = dir.appendingPathComponent("stitched-recovery.wav")
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            let sources = chunkURLs
            let result = try await Task.detached(priority: .utility) {
                var repairedURLs: [URL] = []
                defer { repairedURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
                // An interrupted chunk is read through a repaired copy; the original stays
                // untouched until the recovered audio is safely in the library.
                let readable = try sources.map { chunk -> URL in
                    let copy = dir.appendingPathComponent("repaired-\(chunk.lastPathComponent)")
                    guard try MeetingChunkStitcher.writeRepairedCopy(of: chunk, to: copy) else { return chunk }
                    repairedURLs.append(copy)
                    return copy
                }
                return try MeetingChunkStitcher.stitch(chunkURLs: readable, outputURL: target)
            }.value
            let compressed = await AudioCompressionService.compressToFLAC(wavURL: result.outputURL)
            return StitchOutput(url: compressed, durationSeconds: result.totalDurationSeconds)
        } catch {
            Log.app.error("Meeting recovery stitch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func cleanupInProgress(_ recordingID: UUID) async {
        guard let store = inProgressStore else { return }
        try? await store.cleanup(recordingId: recordingID)
    }
}
