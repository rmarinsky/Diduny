import AVFoundation
import Foundation
import os
import ScreenCaptureKit

@available(macOS 13.0, *)
final class MeetingRecorderService: NSObject, MeetingRecorderServiceProtocol {
    private var systemAudioService: SystemAudioCaptureService?
    private var audioEngine: AVAudioEngine?
    private var mixerNode: AVAudioMixerNode?
    private var audioFile: AVAudioFile?

    private var outputURL: URL?
    private var startTime: Date?

    private(set) var isRecording = false

    /// Returns the current recording file path, if recording
    var currentRecordingPath: String? {
        outputURL?.path
    }

    var audioSource: MeetingAudioSource = .systemOnly
    var onError: ((Error) -> Void)?
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: ((URL?) -> Void)?

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

        // Create output file URL
        let fileName = "meeting_\(Date().timeIntervalSince1970).wav"
        let tempDir = FileManager.default.temporaryDirectory
        outputURL = tempDir.appendingPathComponent(fileName)

        guard let outputURL else {
            throw MeetingRecorderError.fileCreationFailed
        }

        // Start system audio capture
        systemAudioService = SystemAudioCaptureService()
        systemAudioService?.includeMicrophone = (audioSource == .systemPlusMicrophone)

        // Handle stream errors (e.g., error code 2 = attemptToUpdateFilterState)
        systemAudioService?.onError = { [weak self] error in
            Log.recording.error("System audio capture error: \(error.localizedDescription)")
            self?.onError?(error)
        }

        // Handle capture start
        systemAudioService?.onCaptureStarted = { [weak self] in
            Log.recording.info("System audio capture started successfully")
        }

        try await systemAudioService?.startCapture(to: outputURL)

        // If we need microphone too, we'll mix it
        if audioSource == .systemPlusMicrophone {
            // Note: For proper mixing, we'd need a more complex setup
            // For now, ScreenCaptureKit captures system audio
            // Microphone mixing would require AVAudioEngine
            Log.recording.info("Microphone mixing requested - using system audio capture with app audio included")
        }

        isRecording = true
        startTime = Date()

        Log.recording.info("Recording started")
        onRecordingStarted?()
    }

    // MARK: - Stop Recording

    func stopRecording() async throws -> URL? {
        guard isRecording else {
            Log.recording.warning("Not recording")
            return nil
        }

        Log.recording.info("Stopping meeting recording...")

        let savedURL = try await systemAudioService?.stopCapture()
        systemAudioService = nil

        isRecording = false
        startTime = nil

        Log.recording.info("Recording stopped, duration: \(self.recordingDuration) seconds")
        onRecordingStopped?(savedURL)

        return savedURL
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
