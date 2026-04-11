import AVFoundation
import Foundation
import os
import ScreenCaptureKit

final class MeetingRecorderService: NSObject, MeetingRecorderServiceProtocol {
    // MARK: - Properties

    private var systemAudioService: SystemAudioCaptureService?
    private var outputURL: URL?
    private var startTime: Date?

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

        let fileName = "meeting_\(Date().timeIntervalSince1970).wav"
        let tempDir = FileManager.default.temporaryDirectory
        outputURL = tempDir.appendingPathComponent(fileName)

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

        let savedURL = try await systemAudioService?.stopCapture()
        systemAudioService = nil
        isRecording = false

        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        startTime = nil

        Log.recording.info("Recording stopped, duration: \(String(format: "%.2f", duration)) seconds")

        if let url = savedURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attrs[.size] as? Int64
        {
            let sizeMB = Double(fileSize) / 1_000_000.0
            Log.recording.info("Output file size: \(String(format: "%.2f", sizeMB)) MB")
        }

        onRecordingStopped?(savedURL)
        return savedURL
    }

    // MARK: - Cancel Recording

    func cancelRecording() async {
        guard isRecording else { return }

        Log.recording.info("Canceling meeting recording...")

        _ = try? await systemAudioService?.stopCapture()
        systemAudioService = nil

        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil

        isRecording = false
        startTime = nil

        Log.recording.info("Meeting recording canceled")
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
