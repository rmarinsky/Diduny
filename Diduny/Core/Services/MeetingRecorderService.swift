import AVFoundation
import Foundation
import os
import ScreenCaptureKit

@available(macOS 13.0, *)
final class MeetingRecorderService: NSObject, MeetingRecorderServiceProtocol {
    // MARK: - Properties

    private var systemAudioService: SystemAudioCaptureService?
    private var audioMixer: AudioMixerService?
    private var outputURL: URL?
    private var startTime: Date?

    private(set) var isRecording = false

    /// Exposes the system audio capture service for real-time streaming
    var systemAudioCaptureService: SystemAudioCaptureService? {
        systemAudioService
    }

    /// Returns the current recording file path, if recording
    var currentRecordingPath: String? {
        outputURL?.path
    }

    var audioSource: MeetingAudioSource = .systemOnly
    var microphoneDevice: AudioDevice?
    var onError: ((Error) -> Void)?
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: ((URL?) -> Void)?

    /// Called when microphone has been silent for a while (fallback info)
    var onMicrophoneSilent: (() -> Void)?

    /// Called when system audio has been silent for a while (fallback info)
    var onSystemAudioSilent: (() -> Void)?

    var recordingDuration: TimeInterval {
        if let mixer = audioMixer {
            return mixer.recordingDuration
        }
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
        let fileExtension = "wav" // WAV format - reliable and Soniox handles it well
        let fileName = "meeting_\(Date().timeIntervalSince1970).\(fileExtension)"
        let tempDir = FileManager.default.temporaryDirectory
        outputURL = tempDir.appendingPathComponent(fileName)

        guard let outputURL else {
            throw MeetingRecorderError.fileCreationFailed
        }

        // Choose recording strategy based on audio source
        switch audioSource {
        case .systemOnly:
            try await startSystemOnlyRecording(to: outputURL)
        case .systemPlusMicrophone:
            try await startMixedRecording(to: outputURL)
        }

        isRecording = true
        startTime = Date()

        Log.recording.info("Recording started")
        onRecordingStarted?()
    }

    // MARK: - System Only Recording (Simplified Path)

    private func startSystemOnlyRecording(to url: URL) async throws {
        Log.recording.info("Using system-only recording mode (direct file writing)")

        // For system-only, use SystemAudioCaptureService directly (proven to work)
        systemAudioService = SystemAudioCaptureService()
        systemAudioService?.useCallbackMode = false // Write directly to file

        systemAudioService?.onError = { [weak self] error in
            Log.recording.error("System audio capture error: \(error.localizedDescription)")
            self?.onError?(error)
        }

        systemAudioService?.onCaptureStarted = {
            Log.recording.info("System audio capture started successfully")
        }

        // Start system audio capture - writes directly to the output file
        try await systemAudioService?.startCapture(to: url)

        Log.recording.info("System-only recording started")
    }

    // MARK: - Mixed Recording (System + Microphone)

    private func startMixedRecording(to url: URL) async throws {
        Log.recording.info("Using mixed recording mode (system + microphone, AAC output)")

        // Check microphone permission
        let micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        if micPermission == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                Log.recording.warning("Microphone permission denied, falling back to system-only")
                // Fallback to system-only - this is OK, not an error
                try await startSystemOnlyRecording(to: url)
                return
            }
        } else if micPermission != .authorized {
            Log.recording.warning("Microphone permission not authorized, falling back to system-only")
            // Fallback to system-only - this is OK, not an error
            try await startSystemOnlyRecording(to: url)
            return
        }

        // Create mixer with microphone support
        audioMixer = AudioMixerService()

        audioMixer?.onError = { [weak self] error in
            Log.recording.error("Audio mixer error: \(error.localizedDescription)")
            self?.onError?(error)
        }

        audioMixer?.onMicrophoneSilent = { [weak self] in
            // This is informational only - recording continues
            Log.recording.info("Microphone is silent - user may not be speaking (this is OK)")
            self?.onMicrophoneSilent?()
        }

        audioMixer?.onSystemAudioSilent = { [weak self] in
            // This is informational only - recording continues
            Log.recording.info("System audio is silent - meeting may be muted (this is OK)")
            self?.onSystemAudioSilent?()
        }

        // Start system audio capture in callback mode
        systemAudioService = SystemAudioCaptureService()
        systemAudioService?.useCallbackMode = true
        systemAudioService?.onAudioBuffer = { [weak self] sampleBuffer in
            self?.audioMixer?.feedSystemAudio(sampleBuffer)
        }

        systemAudioService?.onError = { error in
            Log.recording.error("System audio capture error: \(error.localizedDescription)")
            // Don't stop recording - microphone still works
            // Just log and continue
        }

        // Start mixer with microphone (use selected device if available)
        try await audioMixer?.startRecording(to: url, includeMicrophone: true, microphoneDevice: microphoneDevice)

        // Then start system audio capture
        let dummyURL = FileManager.default.temporaryDirectory.appendingPathComponent("dummy.wav")
        do {
            try await systemAudioService?.startCapture(to: dummyURL)
        } catch {
            // System audio failed but microphone is still recording
            Log.recording.warning("System audio capture failed, continuing with microphone only: \(error)")
            // Recording continues with just microphone - this is acceptable
        }

        Log.recording.info("Mixed recording started (system + microphone)")
    }

    // MARK: - Cancel Recording

    func cancelRecording() async {
        guard isRecording else { return }

        Log.recording.info("Canceling meeting recording...")

        // Stop mixer first to flush pending writes before deleting output file.
        if let mixer = audioMixer {
            _ = try? await mixer.stopRecording()
        }
        audioMixer = nil

        // Stop system audio capture and clean up callback-mode temp output if any.
        var callbackCaptureURL: URL?
        if let service = systemAudioService {
            callbackCaptureURL = try? await service.stopCapture()
        }
        systemAudioService = nil

        let recordingOutputURL = outputURL
        if let recordingOutputURL {
            try? FileManager.default.removeItem(at: recordingOutputURL)
        }
        outputURL = nil

        if let callbackCaptureURL, callbackCaptureURL != recordingOutputURL {
            try? FileManager.default.removeItem(at: callbackCaptureURL)
        }

        isRecording = false
        startTime = nil

        Log.recording.info("Meeting recording canceled")
    }

    // MARK: - Stop Recording

    func stopRecording() async throws -> URL? {
        guard isRecording else {
            Log.recording.warning("Not recording")
            return nil
        }

        Log.recording.info("Stopping meeting recording...")

        var savedURL: URL?

        // Stop based on which mode we're using
        if audioMixer != nil {
            // Mixed mode: stop mixer first, then system audio
            savedURL = try await audioMixer?.stopRecording()
            audioMixer = nil
            let callbackCaptureURL = try? await systemAudioService?.stopCapture()
            if let callbackCaptureURL, callbackCaptureURL != savedURL {
                try? FileManager.default.removeItem(at: callbackCaptureURL)
            }
        } else {
            // System-only mode: just stop system audio capture
            savedURL = try await systemAudioService?.stopCapture()
        }

        systemAudioService = nil
        isRecording = false

        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        startTime = nil

        Log.recording.info("Recording stopped, duration: \(String(format: "%.2f", duration)) seconds")

        // Get file size for logging
        if let url = savedURL {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let fileSize = attrs[.size] as? Int64
            {
                let sizeMB = Double(fileSize) / 1_000_000.0
                Log.recording.info("Output file size: \(String(format: "%.2f", sizeMB)) MB")
            }
        }

        onRecordingStopped?(savedURL)

        return savedURL
    }

    // MARK: - Get Recording Data

    func getRecordingData() throws -> Data? {
        guard let url = outputURL else { return nil }
        return try Data(contentsOf: url)
    }

    // MARK: - Silence Status (for UI feedback)

    /// Returns true if microphone has been silent for a while (only valid during recording)
    var isMicrophoneSilent: Bool {
        audioMixer?.isMicrophoneSilent ?? true
    }

    /// Returns true if system audio has been silent for a while (only valid during recording)
    var isSystemAudioSilent: Bool {
        audioMixer?.isSystemAudioSilent ?? true
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
