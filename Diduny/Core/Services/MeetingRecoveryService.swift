import AVFoundation
import Foundation

/// Stitches in-progress meeting chunks and attaches them to the live library row.
@MainActor
final class MeetingRecoveryService {
    static let shared = MeetingRecoveryService()

    private let storage: RecordingsLibraryStorage
    private let inProgressStore: InProgressRecordingStore?
    private let stitch: @Sendable ([URL], URL) throws -> MeetingChunkStitcher.Result
    private let frameCount: @Sendable (URL) -> AVAudioFramePosition?

    private init() {
        storage = .shared
        inProgressStore = try? InProgressRecordingStore.sharedStore()
        stitch = Self.defaultStitch
        frameCount = Self.defaultFrameCount
    }

    init(
        storage: RecordingsLibraryStorage,
        inProgressStore: InProgressRecordingStore,
        stitch: @escaping @Sendable ([URL], URL) throws -> MeetingChunkStitcher.Result = MeetingRecoveryService.defaultStitch,
        frameCount: @escaping @Sendable (URL) -> AVAudioFramePosition? = MeetingRecoveryService.defaultFrameCount
    ) {
        self.storage = storage
        self.inProgressStore = inProgressStore
        self.stitch = stitch
        self.frameCount = frameCount
    }

    nonisolated static let defaultStitch: @Sendable ([URL], URL) throws -> MeetingChunkStitcher.Result = {
        try MeetingChunkStitcher.stitch(chunkURLs: $0, outputURL: $1)
    }

    nonisolated static let defaultFrameCount: @Sendable (URL) -> AVAudioFramePosition? = {
        (try? AVAudioFile(forReading: $0))?.length
    }

    enum Outcome {
        case completed
        case failed
        case alreadyRunning
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
    ///
    /// The in-progress directory is the only copy of the audio. It is removed only after the
    /// library file is confirmed to hold every frame of every chunk that has audio.
    @discardableResult
    func resolve(
        recordingID: UUID,
        action: RecoveryAction
    ) async -> Outcome {
        guard inFlightRecordingIDs.insert(recordingID).inserted else {
            Log.app.info("Meeting recovery already in progress for \(recordingID.uuidString), ignoring duplicate request")
            return .alreadyRunning
        }
        defer { inFlightRecordingIDs.remove(recordingID) }

        switch action {
        case .discard:
            if let recording = storage.recordings.first(where: { $0.id == recordingID }),
               !storage.deleteRecording(recording)
            {
                return .failed
            }
            await cleanupInProgress(recordingID)
            return .completed

        case .saveAudioOnly, .processNow:
            guard let stitched = await stitchInProgressAudio(for: recordingID) else {
                reportFailure(recordingID)
                return .failed
            }

            let recording = storage.recordings.first(where: { $0.id == recordingID })
            let endedAt = recording?.endedAt ?? Date()

            let status: Recording.ProcessingStatus = action == .processNow ? .processing : .unprocessed
            let ok = storage.finalizeInProgressRecording(
                id: recordingID,
                audioURL: stitched.url,
                duration: stitched.durationSeconds,
                endedAt: endedAt,
                status: status,
                recoverySource: .orphanedSession,
                forceSave: true
            )
            guard ok else {
                reportFailure(recordingID)
                return .failed
            }

            guard let saved = storage.recordings.first(where: { $0.id == recordingID }),
                  frameCount(storage.audioFileURL(for: saved)) == stitched.frames
            else {
                Log.app.error("Meeting recovery: library file does not hold the expected audio; chunks kept")
                storage.markNeedsRecovery(id: recordingID, endedAt: endedAt)
                reportFailure(recordingID)
                return .failed
            }

            await storage.attachInProgressTracks(from: recordingID, to: recordingID)
            await cleanupInProgress(recordingID)

            if action == .processNow {
                let queueAction: RecordingQueueService.QueueAction =
                    recording?.type == .meetingTranslation ? .translate : .transcribeDiarize
                RecordingQueueService.shared.enqueue([recordingID], action: queueAction)
            }
            return .completed
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
        let frames: AVAudioFramePosition
    }

    private enum StitchFailure: Error {
        case unreadableChunk(String)
        case incomplete(skipped: [Int], expectedFrames: AVAudioFramePosition, writtenFrames: AVAudioFramePosition?)
    }

    /// Every chunk the manifest lists or the disk holds, in index order. A failed or unfinished
    /// rotation update leaves the newest chunk out of the manifest (ADR-0009 D3).
    nonisolated static func chunkURLs(in dir: URL, manifest: InProgressRecordingManifest?) -> [URL] {
        var byIndex: [Int: URL] = [:]
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension == "wav" && url.lastPathComponent.hasPrefix("chunk_") {
            if let index = Int(url.deletingPathExtension().lastPathComponent.dropFirst("chunk_".count)) {
                byIndex[index] = url
            }
        }
        for chunk in manifest?.chunks ?? [] {
            let url = dir.appendingPathComponent(chunk.filename)
            if FileManager.default.fileExists(atPath: url.path) { byIndex[chunk.index] = url }
        }
        return byIndex.keys.sorted().compactMap { byIndex[$0] }
    }

    private func stitchInProgressAudio(for recordingID: UUID) async -> StitchOutput? {
        do {
            guard let store = inProgressStore else { return nil }
            let dir = try await store.directoryURL(for: recordingID)
            // A damaged manifest must not block the chunks the disk scan can still find.
            let manifest = try? await store.readManifest(for: recordingID)
            let sources = Self.chunkURLs(in: dir, manifest: manifest)
            guard !sources.isEmpty else { return nil }

            let target = dir.appendingPathComponent("stitched-recovery.wav")
            let stitch = stitch
            let frameCount = frameCount
            let (result, expectedFrames) = try await Task.detached(priority: .utility) {
                var repairedURLs: [URL] = []
                defer { repairedURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
                // An interrupted chunk is read through a repaired copy; the original stays
                // untouched until the recovered audio is safely in the library.
                var readable: [URL] = []
                var expectedFrames: AVAudioFramePosition = 0
                for chunk in sources where try !MeetingChunkStitcher.hasNoAudio(chunk) {
                    let copy = dir.appendingPathComponent("repaired-\(chunk.lastPathComponent)")
                    repairedURLs.append(copy) // Also removes a copy whose write failed part-way.
                    let source = try MeetingChunkStitcher.writeRepairedCopy(of: chunk, to: copy) ? copy : chunk
                    guard let frames = frameCount(source) else {
                        throw StitchFailure.unreadableChunk(chunk.lastPathComponent)
                    }
                    expectedFrames += frames
                    readable.append(source)
                }
                return (try stitch(readable, target), expectedFrames)
            }.value

            let writtenFrames = frameCount(target)
            guard result.skippedChunks.isEmpty, expectedFrames > 0, writtenFrames == expectedFrames else {
                throw StitchFailure.incomplete(
                    skipped: result.skippedChunks,
                    expectedFrames: expectedFrames,
                    writtenFrames: writtenFrames
                )
            }
            let compressed = await AudioCompressionService.compressToFLAC(wavURL: target)
            let output = frameCount(compressed) == expectedFrames ? compressed : target
            return StitchOutput(url: output, durationSeconds: result.totalDurationSeconds, frames: expectedFrames)
        } catch {
            Log.app.error("Meeting recovery stitch failed, chunks kept: \(String(describing: error))")
            return nil
        }
    }

    private func cleanupInProgress(_ recordingID: UUID) async {
        guard let store = inProgressStore else { return }
        try? await store.cleanup(recordingId: recordingID)
    }
}
