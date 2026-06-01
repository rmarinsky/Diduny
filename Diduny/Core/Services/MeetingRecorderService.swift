import AVFoundation
import Foundation
import os
import ScreenCaptureKit

final class MeetingRecorderService: NSObject, MeetingRecorderServiceProtocol {
    // MARK: - Properties

    private var systemAudioService: SystemAudioCaptureService?
    private var outputURL: URL?
    private var startTime: Date?
    /// UUID of the active in-progress recording directory (nil when not recording).
    private(set) var currentRecordingId: UUID?
    /// Per-recording in-progress directory under Application Support. Owned by the store.
    private var inProgressDirectoryURL: URL?
    /// Ordered list of chunk URLs for the active recording (closed + currently writing).
    /// Used at stop time to drive `MeetingChunkStitcher`.
    private var chunkURLs: [URL] = []
    /// Chunk-rotation interval forwarded to `SystemAudioCaptureService`. Tests override; production uses default.
    var chunkDurationSeconds: TimeInterval = 300

    private(set) var isRecording = false

    var systemAudioCaptureService: SystemAudioCaptureService? {
        systemAudioService
    }

    var currentRecordingPath: String? {
        outputURL?.path
    }

    var audioSource: MeetingAudioSource = .systemOnly
    var microphoneDevice: AudioDevice?
    var onError: ((Error) -> Void)?
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: ((URL?) -> Void)?
    var onRealtimeAudioData: ((Data) -> Void)? {
        didSet {
            systemAudioService?.onRawAudioData = onRealtimeAudioData
        }
    }

    var onMicrophoneSilent: (() -> Void)?
    var onSystemAudioSilent: (() -> Void)?
    var onStatusMessage: ((String) -> Void)?

    var recordingDuration: TimeInterval {
        guard let start = startTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Permission Check

    static func checkPermission() async -> Bool {
        await SystemAudioCaptureService.checkPermission()
    }

    // MARK: - Start Recording

    func startRecording() async throws {
        guard !isRecording else {
            Log.recording.warning("Already recording")
            return
        }

        Log.recording.info("Starting meeting recording, source: \(self.audioSource.displayName)")

        // Allocate a stable per-recording directory under Application Support.
        // This replaces the old temporaryDirectory approach (RLR-M1).
        let recordingId = UUID()
        let directoryURL: URL
        let firstChunkURL: URL
        do {
            let store = try InProgressRecordingStore.sharedStore()
            directoryURL = try await store.directoryURL(for: recordingId)
            firstChunkURL = directoryURL.appendingPathComponent(Self.chunkFilename(forIndex: 1))
        } catch {
            Log.recording.error("Failed to create in-progress recording directory: \(error)")
            throw MeetingRecorderError.fileCreationFailed
        }
        currentRecordingId = recordingId
        inProgressDirectoryURL = directoryURL
        chunkURLs = [firstChunkURL]
        outputURL = firstChunkURL

        guard let outputURL else {
            throw MeetingRecorderError.fileCreationFailed
        }

        // Determine whether to capture microphone
        var enableMic = false
        if audioSource == .systemPlusMicrophone {
            let micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
            if micPermission == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                enableMic = granted
                if !granted {
                    Log.recording.warning("Microphone permission denied, falling back to system-only")
                }
            } else if micPermission == .authorized {
                enableMic = true
            } else {
                Log.recording.warning("Microphone permission not authorized, falling back to system-only")
            }
        }

        let service = SystemAudioCaptureService()
        service.captureMicrophone = enableMic
        service.microphoneDevice = enableMic ? microphoneDevice : nil
        service.micGain = SettingsStorage.shared.meetingMicGain
        service.systemGain = SettingsStorage.shared.meetingSystemGain
        service.onRawAudioData = onRealtimeAudioData
        service.onStatusMessage = { [weak self] message in
            self?.onStatusMessage?(message)
        }

        // Chunk rotation wiring (RLR-M3b).
        service.chunkDurationSeconds = chunkDurationSeconds
        service.chunkURLProvider = { [directoryURL] index in
            directoryURL.appendingPathComponent(Self.chunkFilename(forIndex: index))
        }
        service.onChunkRotated = { [weak self] closedIndex, closedURL, closedAt, byteCount, durationSeconds in
            self?.handleChunkRotated(
                closedIndex: closedIndex,
                closedURL: closedURL,
                closedAt: closedAt,
                byteCount: byteCount,
                durationSeconds: durationSeconds,
                directoryURL: directoryURL
            )
        }

        service.onError = { [weak self] error in
            Log.recording.error("Audio capture error: \(error.localizedDescription)")
            self?.onError?(error)
        }

        service.onCaptureStarted = {
            Log.recording.info("Audio capture started successfully")
        }

        service.onMicrophoneSilent = { [weak self] in
            Log.recording.info("Microphone is silent (informational)")
            self?.onMicrophoneSilent?()
        }

        service.onSystemAudioSilent = { [weak self] in
            Log.recording.info("System audio is silent (informational)")
            self?.onSystemAudioSilent?()
        }

        systemAudioService = service

        try await service.startCapture(to: outputURL)

        isRecording = true
        startTime = Date()

        // Write initial manifest so recovery can find this session immediately.
        // Chunks are 16 kHz mono 16-bit regardless of capture mode (mic+system are mixed to mono).
        let initialManifest = InProgressRecordingManifest(
            id: recordingId,
            schemaVersion: 1,
            type: .meeting,
            startedAt: startTime!,
            sourceDevice: nil,
            audioConfig: InProgressRecordingManifest.AudioConfig(
                sampleRate: 16000,
                channels: 1,
                bitDepth: 16
            ),
            chunks: [
                InProgressRecordingManifest.ChunkEntry(
                    index: 1,
                    filename: Self.chunkFilename(forIndex: 1),
                    byteCount: 0,
                    durationSeconds: 0,
                    closedAt: nil
                )
            ],
            lastWriteAt: startTime!,
            recordingInterruptedBySleep: false
        )
        if let store = try? InProgressRecordingStore.sharedStore() {
            try? await store.writeManifest(initialManifest, for: recordingId)
        }

        Log.recording.info("Recording started (captureMicrophone=\(service.captureMicrophone))")
        onRecordingStarted?()
    }

    // MARK: - Stop Recording

    func stopRecording() async throws -> URL? {
        guard isRecording else {
            Log.recording.warning("Not recording")
            return nil
        }

        Log.recording.info("Stopping meeting recording...")

        let capturedRecordingId = currentRecordingId
        let capturedChunkURLs = chunkURLs
        let capturedDirectoryURL = inProgressDirectoryURL
        _ = try await systemAudioService?.stopCapture()
        systemAudioService = nil
        isRecording = false

        let stopTime = Date()
        let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0
        startTime = nil
        currentRecordingId = nil
        inProgressDirectoryURL = nil
        chunkURLs = []

        Log.recording.info(
            "Recording stopped, duration: \(String(format: "%.2f", duration))s across \(capturedChunkURLs.count) chunks"
        )

        // Stitch all chunks into a single output WAV (RLR-M4). Sits alongside the in-progress
        // directory so the directory cleanup downstream removes it together. The stitched file
        // lives at <dir>/stitched.wav until the AppDelegate hands it off to the library.
        let stitchedURL: URL?
        let stitchResult: MeetingChunkStitcher.Result?
        if let dir = capturedDirectoryURL, !capturedChunkURLs.isEmpty {
            let target = dir.appendingPathComponent("stitched.wav")
            do {
                let result = try MeetingChunkStitcher.stitch(chunkURLs: capturedChunkURLs, outputURL: target)
                stitchResult = result
                stitchedURL = result.outputURL
                Log.recording.info(
                    "Stitch ok: appended=\(result.appendedChunkCount) skipped=\(result.skippedChunks) totalDur=\(String(format: "%.2f", result.totalDurationSeconds))s"
                )
            } catch {
                Log.recording.error("Stitch FAILED: \(error.localizedDescription) — falling back to last chunk only")
                stitchResult = nil
                stitchedURL = capturedChunkURLs.last
            }
        } else {
            stitchResult = nil
            stitchedURL = capturedChunkURLs.last
        }

        var stitchedSize: Int64 = 0
        if let url = stitchedURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64
        {
            stitchedSize = size
            Log.recording.info("Stitched file size: \(String(format: "%.2f", Double(size) / 1_000_000.0)) MB")
        }
        _ = stitchedSize

        // Update manifest: mark the last (currently-writing) chunk as cleanly closed.
        // Earlier chunks already have closedAt set by handleChunkRotated; nothing to update there.
        if let recordingId = capturedRecordingId,
           let store = try? InProgressRecordingStore.sharedStore(),
           var manifest = try? await store.readManifest(for: recordingId),
           !manifest.chunks.isEmpty,
           let lastChunkURL = capturedChunkURLs.last
        {
            let lastIdx = manifest.chunks.count - 1
            var lastByteCount: Int64 = 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: lastChunkURL.path),
               let size = attrs[.size] as? Int64
            {
                lastByteCount = size
            }
            let lastDuration: Double
            if let stitch = stitchResult {
                // Subtract durations of preceding (closed) chunks from total.
                let priorDurations = manifest.chunks.prefix(manifest.chunks.count - 1)
                    .reduce(0.0) { $0 + $1.durationSeconds }
                lastDuration = max(0, stitch.totalDurationSeconds - priorDurations)
            } else {
                // Stitch unavailable (no rotation happened): the whole recording is in chunk_001.
                lastDuration = duration
            }
            manifest.chunks[lastIdx].closedAt = stopTime
            manifest.chunks[lastIdx].byteCount = lastByteCount
            manifest.chunks[lastIdx].durationSeconds = lastDuration
            manifest.lastWriteAt = stopTime
            try? await store.writeManifest(manifest, for: recordingId)
        }

        onRecordingStopped?(stitchedURL)
        return stitchedURL
    }

    // MARK: - Sleep Flush

    /// Synchronously flushes and closes the current audio file chunk for the
    /// `willSleepNotification` handler.
    ///
    /// Called on a power-management background thread (NOT MainActor / not async).
    /// The `AVAudioFile` close inside `SystemAudioCaptureService.synchronousFlushForSleep()`
    /// is already synchronous — no `DispatchSemaphore` is needed.
    ///
    /// After calling this, `isRecording` remains true at the service level until the caller
    /// updates AppState. The manifest `recordingInterruptedBySleep` flag is set by the caller
    /// (AppDelegate) via an async `Task` spawned after this method returns.
    ///
    /// Returns the URL of the flushed audio file, or nil if not recording.
    func synchronousFlushForSleep() -> URL? {
        guard isRecording, let service = systemAudioService else {
            Log.recording.info("[Sleep] synchronousFlushForSleep: not recording, skipping")
            return nil
        }
        let url = service.synchronousFlushForSleep()
        Log.recording.info("[Sleep] synchronousFlushForSleep: chunk closed at \(url?.path ?? "nil")")
        return url
    }

    // MARK: - Cancel Recording

    func cancelRecording() async {
        guard isRecording else { return }

        Log.recording.info("Canceling meeting recording...")

        let capturedRecordingId = currentRecordingId
        _ = try? await systemAudioService?.stopCapture()
        systemAudioService = nil
        outputURL = nil
        isRecording = false
        startTime = nil
        currentRecordingId = nil
        inProgressDirectoryURL = nil
        chunkURLs = []

        // Remove the entire in-progress directory (chunks + manifest + any stitched output).
        if let recordingId = capturedRecordingId {
            if let store = try? InProgressRecordingStore.sharedStore() {
                try? await store.cleanup(recordingId: recordingId)
            }
        }

        Log.recording.info("Meeting recording canceled")
    }

    // MARK: - Chunk Rotation Handling (RLR-M3b)

    /// Fired by `SystemAudioCaptureService` on `fileWriteQueue` whenever a chunk rotates.
    /// Spawns an async Task to (a) append a new ChunkEntry for the freshly-opened chunk and
    /// (b) finalize the closed chunk's metadata. Manifest writes are best-effort; failures
    /// are logged but do not abort the recording.
    private func handleChunkRotated(
        closedIndex: Int,
        closedURL: URL,
        closedAt: Date,
        byteCount: Int64,
        durationSeconds: Double,
        directoryURL: URL
    ) {
        let newIndex = closedIndex + 1
        let newURL = directoryURL.appendingPathComponent(Self.chunkFilename(forIndex: newIndex))

        // Mutate our chunkURLs list synchronously on whatever queue this fires from.
        // SystemAudioCaptureService fires from fileWriteQueue; appending to chunkURLs is safe
        // because every other reader (stopRecording / cancelRecording) only runs after the
        // capture service is shut down. Concurrent writers do not exist.
        chunkURLs.append(newURL)

        guard let recordingId = currentRecordingId else { return }
        Task { [weak self] in
            guard self != nil else { return }
            do {
                let store = try InProgressRecordingStore.sharedStore()
                guard var manifest = try await store.readManifest(for: recordingId) else { return }
                // Update closed entry (1-based → 0-based index)
                let closedIdx0 = closedIndex - 1
                if manifest.chunks.indices.contains(closedIdx0) {
                    manifest.chunks[closedIdx0].closedAt = closedAt
                    manifest.chunks[closedIdx0].byteCount = byteCount
                    manifest.chunks[closedIdx0].durationSeconds = durationSeconds
                }
                // Append entry for the new (now active) chunk, idempotently
                if !manifest.chunks.contains(where: { $0.index == newIndex }) {
                    manifest.chunks.append(
                        InProgressRecordingManifest.ChunkEntry(
                            index: newIndex,
                            filename: Self.chunkFilename(forIndex: newIndex),
                            byteCount: 0,
                            durationSeconds: 0,
                            closedAt: nil
                        )
                    )
                }
                manifest.lastWriteAt = Date()
                try await store.writeManifest(manifest, for: recordingId)
            } catch {
                Log.recording.warning("[ChunkRotate] manifest update failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stable filename format for chunk files. Padded to 3 digits to keep
    /// `contentsOfDirectory` order stable up to 999 chunks (= 83 h at 5 min).
    static func chunkFilename(forIndex index: Int) -> String {
        String(format: "chunk_%03d.wav", index)
    }

    // MARK: - Get Recording Data

    func getRecordingData() throws -> Data? {
        guard let url = outputURL else { return nil }
        return try Data(contentsOf: url)
    }
}

// MARK: - Errors

enum MeetingRecorderError: LocalizedError {
    case fileCreationFailed
    case permissionDenied
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .fileCreationFailed:
            "Failed to create recording file"
        case .permissionDenied:
            "Screen recording permission required for meeting capture"
        case .recordingFailed:
            "Failed to start recording"
        }
    }
}
