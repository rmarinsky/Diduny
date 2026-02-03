import AVFoundation
import Combine
import CoreAudio
import Foundation
import os

/// Error thrown when audio operations exceed the allowed time limit
struct AudioTimeoutError: Error, LocalizedError {
    let operation: String
    let timeout: TimeInterval

    var errorDescription: String? {
        "Audio operation '\(operation)' timed out after \(Int(timeout)) seconds. " +
            "This may indicate an audio device issue. Please try again or select a different microphone."
    }
}

@MainActor
final class AudioRecorderService: ObservableObject, AudioRecorderProtocol {
    @Published private(set) var isRecording = false
    @Published private(set) var audioLevel: Float = 0

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var configurationObserver: NSObjectProtocol?

    /// Timeout for audio hardware operations (in seconds)
    private let audioOperationTimeout: TimeInterval = 2.0

    /// Returns the current recording file path, if recording
    var currentRecordingPath: String? {
        recordingURL?.path
    }

    // MARK: - Public Methods

    func startRecording(device: AudioDevice?, quality: AudioQuality) async throws {
        Log.audio.info("startRecording: BEGIN, isRecording=\(self.isRecording)")
        guard !isRecording else {
            Log.audio.warning("startRecording: Already recording, returning")
            return
        }

        // Request microphone permission
        var permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.audio.info("startRecording: Permission status = \(permissionStatus.rawValue)")

        if permissionStatus == .notDetermined {
            Log.audio.info("startRecording: Requesting permission")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.audio.info("startRecording: Permission request result = \(granted)")
            permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }

        guard permissionStatus == .authorized else {
            Log.audio.warning("startRecording: Permission denied")
            throw AudioError.permissionDenied
        }

        // Set input device if specified
        if let device {
            Log.audio.info("startRecording: Setting input device: \(device.name)")
            setInputDevice(device.id)
        }

        // Create and configure audio engine
        let engine = AVAudioEngine()
        audioEngine = engine

        // Set up input device on the engine
        // IMPORTANT: Accessing engine.inputNode can hang indefinitely if CoreAudio/coreaudiod is unresponsive
        // We wrap this in a timeout to prevent the app from freezing
        let deviceID = device?.id
        let inputFormat: AVAudioFormat
        let inputNode: AVAudioInputNode

        do {
            Log.audio.info("startRecording: Initializing audio engine with \(self.audioOperationTimeout)s timeout")

            // Run audio hardware initialization with timeout to prevent hanging
            let result = try await withAudioTimeout(
                operation: "audio engine initialization",
                timeout: audioOperationTimeout
            ) { [engine] () async throws -> (AVAudioInputNode, AVAudioFormat) in
                // This runs in a detached context to avoid blocking MainActor
                // Set device on the audio unit if specified
                if let deviceID {
                    let node = engine.inputNode
                    if let audioUnit = node.audioUnit {
                        var mutableDeviceID = deviceID
                        AudioUnitSetProperty(
                            audioUnit,
                            kAudioOutputUnitProperty_CurrentDevice,
                            kAudioUnitScope_Global,
                            0,
                            &mutableDeviceID,
                            UInt32(MemoryLayout<AudioDeviceID>.size)
                        )
                    }
                }

                // Access inputNode - this is where the hang typically occurs
                let node = engine.inputNode
                let format = node.outputFormat(forBus: 0)
                return (node, format)
            }

            inputNode = result.0
            inputFormat = result.1
            Log.audio.info("startRecording: Audio engine initialized successfully")
        } catch let error as AudioTimeoutError {
            Log.audio.error("startRecording: \(error.localizedDescription)")
            audioEngine = nil
            throw AudioError.recordingFailed(error.localizedDescription)
        }

        Log.audio.info("startRecording: Input format - sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")

        // Create temporary file URL
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "dictate_\(UUID().uuidString).wav"
        recordingURL = tempDir.appendingPathComponent(fileName)
        Log.audio.info("startRecording: Recording URL = \(self.recordingURL?.path ?? "nil")")

        guard let url = recordingURL else {
            Log.audio.error("startRecording: Failed to create URL")
            throw AudioError.recordingFailed("Could not create recording file")
        }

        // Create audio file for writing - use the INPUT format to avoid realtime conversion
        // The transcription service can handle various formats
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
        } catch {
            Log.audio.error("startRecording: Failed to create audio file: \(error.localizedDescription)")
            throw AudioError.recordingFailed("Could not create audio file: \(error.localizedDescription)")
        }

        Log.audio.info("startRecording: Audio file created with input format settings")

        // Capture file reference for use in tap callback (runs on audio thread)
        guard let file = audioFile else {
            throw AudioError.recordingFailed("Audio file not initialized")
        }

        // Install tap on input node to capture audio
        // IMPORTANT: This callback runs on a realtime audio thread, NOT the main thread
        // Write directly in the input format - no conversion needed
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // Update audio level from buffer (thread-safe method)
            self?.updateAudioLevelFromBuffer(buffer)

            // Write buffer directly to file - no format conversion
            do {
                try file.write(from: buffer)
            } catch {
                Log.audio.error("Failed to write audio buffer: \(error.localizedDescription)")
            }
        }

        // Observe configuration changes for handling device switching
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleConfigurationChange()
            }
        }

        // Start the engine
        do {
            try engine.start()
            Log.audio.info("startRecording: Audio engine started")
        } catch {
            Log.audio.error("startRecording: Failed to start engine: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            throw AudioError.recordingFailed("Failed to start audio engine: \(error.localizedDescription)")
        }

        isRecording = true
        Log.audio.info("startRecording: END, isRecording=\(self.isRecording)")
    }

    func stopRecording() async throws -> Data {
        Log.audio.info("stopRecording: BEGIN, isRecording=\(self.isRecording)")
        guard isRecording, let engine = audioEngine, let url = recordingURL else {
            let logMsg = "stopRecording: No active recording! isRecording=\(isRecording), " +
                "engine=\(audioEngine != nil), url=\(recordingURL?.path ?? "nil")"
            Log.audio.warning("\(logMsg)")
            throw AudioError.recordingFailed("No active recording")
        }

        Log.audio.info("stopRecording: Removing tap and stopping engine")

        // Remove tap and stop engine
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Remove configuration observer
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }

        // Close the audio file
        audioFile = nil

        isRecording = false
        audioLevel = 0

        // Read audio data
        Log.audio.info("stopRecording: Reading audio data from \(url.path)")
        let audioData = try Data(contentsOf: url)
        Log.audio.info("stopRecording: Read \(audioData.count) bytes")

        // Cleanup
        try? FileManager.default.removeItem(at: url)
        audioEngine = nil
        recordingURL = nil

        Log.audio.info("stopRecording: END")
        return audioData
    }

    func cancelRecording() {
        guard let engine = audioEngine else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }

        audioFile = nil
        audioEngine = nil

        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }

        isRecording = false
        audioLevel = 0
    }

    // MARK: - Private Methods

    private func setInputDevice(_ deviceID: AudioDeviceID) {
        // Set the default input device using CoreAudio
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var mutableDeviceID = deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            dataSize,
            &mutableDeviceID
        )
    }

    private func setEngineInputDevice(_ engine: AVAudioEngine, deviceID: AudioDeviceID) {
        // Set the audio unit's input device directly
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else { return }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            Log.audio.warning("Failed to set engine input device: \(status)")
        }
    }

    private func handleConfigurationChange() {
        Log.audio.info("Audio configuration changed - handling device switch")

        guard isRecording, let engine = audioEngine else { return }

        // The engine automatically handles configuration changes in most cases
        // Just ensure it's still running
        if !engine.isRunning {
            do {
                try engine.start()
                Log.audio.info("Audio engine restarted after configuration change")
            } catch {
                Log.audio.error("Failed to restart engine after config change: \(error.localizedDescription)")
                // Recording will continue to fail, but we don't want to crash
            }
        }
    }

    private nonisolated func updateAudioLevelFromBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        // Calculate RMS (Root Mean Square) for audio level
        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))

        // Convert to dB and normalize
        let db = 20 * log10(max(rms, 0.0001))
        let minDb: Float = -60
        let normalizedLevel = max(0, min(1, (db - minDb) / -minDb))

        Task { @MainActor [weak self] in
            self?.audioLevel = normalizedLevel
        }
    }

    // MARK: - Timeout Helper

    /// Executes an operation with a timeout. Throws AudioTimeoutError if the operation exceeds the time limit.
    /// Note: This uses a detached task to avoid MainActor blocking during audio hardware operations.
    private func withAudioTimeout<T: Sendable>(
        operation: String,
        timeout: TimeInterval,
        work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Add the actual work task
            group.addTask {
                try await work()
            }

            // Add the timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AudioTimeoutError(operation: operation, timeout: timeout)
            }

            // Return the first result (either success or timeout)
            guard let result = try await group.next() else {
                throw AudioTimeoutError(operation: operation, timeout: timeout)
            }

            // Cancel the remaining task (either the work or the timeout)
            group.cancelAll()
            return result
        }
    }
}
