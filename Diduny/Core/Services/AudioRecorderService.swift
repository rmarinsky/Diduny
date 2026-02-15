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
    private var realtimeAudioStreamer: RealtimeAudioStreamer?

    /// Timeout for audio hardware operations (in seconds)
    /// Increased to 5s to support older Intel Macs which can be slower
    private let audioOperationTimeout: TimeInterval = 5.0

    /// Returns the current recording file path, if recording
    var currentRecordingPath: String? {
        recordingURL?.path
    }

    /// Real-time PCM stream in `s16le`, 16kHz, mono for cloud websocket transcription/translation.
    var onRealtimeAudioData: ((Data) -> Void)?

    // MARK: - Public Methods

    func startRecording(device: AudioDevice?) async throws {
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

        // Validate audio format - on some Intel Macs, the format can be invalid
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Log.audio.error("startRecording: Invalid audio format - sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")
            audioEngine = nil
            throw AudioError.recordingFailed("Invalid audio format. Please try selecting a different microphone in Settings.")
        }

        // Create temporary file URL
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "diduny_\(UUID().uuidString).wav"
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

        // Optional realtime streamer for websocket mode (translation/live features)
        let realtimeAudioStreamer = makeRealtimeAudioStreamerIfNeeded(inputFormat: inputFormat)
        self.realtimeAudioStreamer = realtimeAudioStreamer

        // Install tap on input node to capture audio
        // IMPORTANT: This callback runs on a realtime audio thread, NOT the main thread
        // Write directly in the input format - no conversion needed
        // NOTE: installTap is synchronous and must be called on the main thread.
        // Do NOT wrap this in withAudioTimeout as it causes threading issues on Intel Macs.
        Log.audio.info("startRecording: Installing tap on input node...")
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // Update audio level from buffer (thread-safe method)
            self?.updateAudioLevelFromBuffer(buffer)

            // Write buffer directly to file - no format conversion
            do {
                try file.write(from: buffer)
            } catch {
                Log.audio.error("Failed to write audio buffer: \(error.localizedDescription)")
            }

            realtimeAudioStreamer?.process(buffer: buffer)
        }
        Log.audio.info("startRecording: Tap installed successfully")

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
        // NOTE: Do NOT wrap in withAudioTimeout - it causes threading issues/deadlocks on Intel Macs
        // because TaskGroup runs on background threads while AVAudioEngine needs main thread
        do {
            Log.audio.info("startRecording: Starting audio engine...")
            try engine.start()
            Log.audio.info("startRecording: Audio engine started")

            // Verify engine is actually running
            guard engine.isRunning else {
                Log.audio.error("startRecording: Engine started but isRunning=false")
                inputNode.removeTap(onBus: 0)
                throw AudioError.recordingFailed("Audio engine failed to start. Please try a different microphone.")
            }
            Log.audio.info("startRecording: Engine verified running")
        } catch {
            Log.audio.error("startRecording: Failed to start engine: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            if let observer = configurationObserver {
                NotificationCenter.default.removeObserver(observer)
                configurationObserver = nil
            }
            audioEngine = nil
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
        let audioData = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
        Log.audio.info("stopRecording: Read \(audioData.count) bytes")

        // Cleanup
        try? FileManager.default.removeItem(at: url)
        audioEngine = nil
        recordingURL = nil
        realtimeAudioStreamer = nil

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

        realtimeAudioStreamer = nil
        isRecording = false
        audioLevel = 0
    }

    // MARK: - Private Methods

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

    private func makeRealtimeAudioStreamerIfNeeded(inputFormat: AVAudioFormat) -> RealtimeAudioStreamer? {
        guard let callback = onRealtimeAudioData else { return nil }
        return RealtimeAudioStreamer(inputFormat: inputFormat, onAudioData: callback)
    }
}

private final class RealtimeAudioStreamer {
    private let queue = DispatchQueue(label: "ua.com.rmarinsky.diduny.realtime.mic", qos: .userInitiated)
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let onAudioData: (Data) -> Void

    init?(inputFormat: AVAudioFormat, onAudioData: @escaping (Data) -> Void) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            return nil
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }

        self.converter = converter
        self.outputFormat = outputFormat
        self.onAudioData = onAudioData
    }

    func process(buffer: AVAudioPCMBuffer) {
        guard let copiedBuffer = copyBuffer(buffer) else { return }

        queue.async { [weak self] in
            guard let self else { return }
            guard let data = self.convertToRealtimePCM(buffer: copiedBuffer) else { return }
            self.onAudioData(data)
        }
    }

    private func convertToRealtimePCM(buffer: AVAudioPCMBuffer) -> Data? {
        let inputFormat = buffer.format
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard outputFrameCapacity > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        var hasInputData = true

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasInputData {
                hasInputData = false
                outStatus.pointee = .haveData
                return buffer
            }

            outStatus.pointee = .noDataNow
            return nil
        }

        guard error == nil, status != .error, outputBuffer.frameLength > 0 else {
            if let error {
                Log.audio.error("RealtimeAudioStreamer conversion error: \(error.localizedDescription)")
            }
            return nil
        }

        let audioBufferPointer = UnsafeMutableAudioBufferListPointer(outputBuffer.mutableAudioBufferList)
        guard let audioBuffer = audioBufferPointer.first,
              let dataPtr = audioBuffer.mData,
              audioBuffer.mDataByteSize > 0
        else {
            return nil
        }

        return Data(bytes: dataPtr, count: Int(audioBuffer.mDataByteSize))
    }

    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameCount = buffer.frameLength
        guard frameCount > 0 else { return nil }
        let format = buffer.format

        guard let copiedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        copiedBuffer.frameLength = frameCount

        let sourceList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destinationList = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)
        let bufferCount = min(sourceList.count, destinationList.count)

        for index in 0 ..< bufferCount {
            let source = sourceList[index]
            let destination = destinationList[index]
            guard let sourceData = source.mData, let destinationData = destination.mData else { continue }
            let byteCount = min(Int(source.mDataByteSize), Int(destination.mDataByteSize))
            memcpy(destinationData, sourceData, byteCount)
        }

        return copiedBuffer
    }
}
