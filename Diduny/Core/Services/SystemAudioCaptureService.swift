import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

final class SystemAudioCaptureService: NSObject {
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var isCapturing = false
    private var isStoppingCapture = false
    private var outputFormat: AVAudioFormat?
    private var sampleCount: Int = 0
    private var lastFlushTime: Date = .init()
    private let flushInterval: TimeInterval = 30.0

    // Microphone capture via AVAudioEngine (SCStream's captureMicrophone is unreliable)
    private var micEngine: AVAudioEngine?
    private var micConverter: AVAudioConverter?
    private var micConfigurationObserver: NSObjectProtocol?
    private var systemRecoveryTask: Task<Void, Never>?
    private var microphoneRecoveryTask: Task<Void, Never>?
    private var isRecoveringSystem = false
    private var isRecoveringMicrophone = false

    private let realtimeQueue = DispatchQueue(label: "ua.com.rmarinsky.diduny.realtime", qos: .userInitiated)
    private let fileWriteQueue = DispatchQueue(label: "ua.com.rmarinsky.diduny.systemaudio.write")
    /// Serial queue for mixer buffer access — both SCStream callbacks and AVAudioEngine tap dispatch here.
    private let mixerQueue = DispatchQueue(label: "ua.com.rmarinsky.diduny.mixer")
    private let streamOutputQueue = DispatchQueue(label: "ua.com.rmarinsky.diduny.scstream.output")
    private let maxSystemRecoveryAttempts = 3
    private let maxMicrophoneRecoveryAttempts = 3
    private let initialRecoveryDelay: TimeInterval = 0.75

    // MARK: - Chunk Rotation State (accessed only on fileWriteQueue)

    /// 1-based index of the chunk currently being written.
    private var currentChunkIndex: Int = 1
    /// Wall-clock time when the current chunk file was opened.
    private var currentChunkStartedAt: Date = .init()
    /// Frames written into the current chunk; used to compute durationSeconds on rotation.
    private var currentChunkFrameCount: Int = 0

    // MARK: - Public Configuration

    /// Enable microphone capture alongside system audio.
    var captureMicrophone: Bool = false

    /// The microphone device to use. `nil` = system default.
    var microphoneDevice: AudioDevice?

    /// Gain applied to microphone samples before mixing (0–2, default 1.0).
    var micGain: Float = 1.0

    /// Gain applied to system audio samples before mixing with microphone (0–2, default 0.3).
    var systemGain: Float = 0.3

    /// Wall-clock duration of a single chunk file before rotation (RLR-M3b).
    /// Default 300 s (5 min) per ADR-0009 §D3. Tests may shrink this.
    var chunkDurationSeconds: TimeInterval = 300

    /// Supplies the URL for chunk `index` (1-based).
    /// When `nil`, rotation is disabled and the service writes the entire capture to the URL
    /// passed to `startCapture(to:)` (legacy single-file mode used by non-meeting modes / tests).
    var chunkURLProvider: ((Int) -> URL)?

    /// Fired on the fileWriteQueue when a chunk file is closed (rotation boundary).
    /// Params: closedIndex, closedURL, closedAt, byteCount, durationSeconds.
    /// The caller is expected to spawn an async Task to update the on-disk manifest;
    /// the callback itself must not block.
    var onChunkRotated: ((Int, URL, Date, Int64, Double) -> Void)?

    var onError: ((Error) -> Void)?
    var onCaptureStarted: (() -> Void)?

    /// Raw mono s16le PCM data callback for cloud real-time transcription.
    var onRawAudioData: ((Data) -> Void)?

    /// Fired when microphone has been silent for > `silenceTimeout`.
    var onMicrophoneSilent: (() -> Void)?

    /// Fired when system audio has been silent for > `silenceTimeout`.
    var onSystemAudioSilent: (() -> Void)?

    /// Informational runtime status updates (recovery attempts, fallbacks, etc.)
    var onStatusMessage: ((String) -> Void)?

    // MARK: - Inline Mixer State (accessed only on mixerQueue)

    private var systemBuffer: [Float] = []
    private var micBuffer: [Float] = []
    /// Maximum single-source frames before flushing without counterpart.
    /// This bounds live-transcription latency when one source temporarily leads
    /// the other, while still giving the mixer a chance to align overlapping audio.
    private let flushThresholdFrames = 8000

    // MARK: - Silence Detection (accessed only on mixerQueue)

    private let silenceTimeout: TimeInterval = 5.0
    private let silenceRMSThreshold: Float = 0.001
    private var lastNonSilentSystemTime: Date = .init()
    private var lastNonSilentMicTime: Date = .init()
    private var didFireSystemSilent = false
    private var didFireMicSilent = false

    private var rawAudioCallbackCount = 0
    private var systemBufferCount = 0
    private var micBufferCount = 0
    private var delegateCallCount = 0

    private var microphoneCaptureStarted = false

    // MARK: - Permission Check

    static func checkPermission() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return !content.displays.isEmpty
        } catch {
            Log.audio.error("Permission check failed: \(error)")
            return false
        }
    }

    static func requestPermission() async -> Bool {
        await checkPermission()
    }

    // MARK: - Start Capture

    func startCapture(to outputURL: URL) async throws {
        guard !isCapturing else {
            Log.audio.warning("Already capturing")
            return
        }

        self.outputURL = outputURL
        isStoppingCapture = false
        cancelRecoveryTasks()
        isRecoveringSystem = false
        isRecoveringMicrophone = false

        let captureMicrophoneAtStart = captureMicrophone
        Log.audio.info("Starting system audio capture (captureMicrophone=\(captureMicrophoneAtStart))...")

        try setupAudioFile(at: outputURL)

        // Reset chunk rotation state (RLR-M3b)
        currentChunkIndex = 1
        currentChunkStartedAt = Date()
        currentChunkFrameCount = 0

        // Reset mixer state
        systemBuffer.removeAll()
        micBuffer.removeAll()
        let now = Date()
        lastNonSilentSystemTime = now
        lastNonSilentMicTime = now
        didFireSystemSilent = false
        didFireMicSilent = false
        rawAudioCallbackCount = 0
        systemBufferCount = 0
        micBufferCount = 0
        delegateCallCount = 0
        microphoneCaptureStarted = false

        try await createAndStartSystemStream()
        isCapturing = true
        lastFlushTime = Date()

        // Start microphone capture via AVAudioEngine if requested
        if captureMicrophone {
            do {
                try startMicrophoneCapture()
                microphoneCaptureStarted = true
                NSLog(
                    "[AudioCapture] Microphone engine started (device: %@)",
                    microphoneDevice?.name ?? "system default"
                )
            } catch {
                Log.audio.error("Microphone capture failed during meeting start: \(error.localizedDescription)")
                NSLog("[AudioCapture] ERROR: Microphone capture failed: %@", error.localizedDescription)
                captureMicrophone = false
                microphoneDevice = nil
                microphoneCaptureStarted = false
                emitStatusMessage("Microphone unavailable. Recording system audio only")
            }
        }

        let captureMicrophoneAfterStart = captureMicrophone
        Log.audio.info("Capture started (16kHz mono, captureMicrophone=\(captureMicrophoneAfterStart))")
        NSLog("[AudioCapture] Capture started — waiting for delegate callbacks...")
        onCaptureStarted?()
    }

    private func createAndStartSystemStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = makeStreamConfiguration()

        NSLog("[AudioCapture] Creating SCStream (system audio only)")

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamOutputQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: streamOutputQueue)
            self.stream = stream
            try await stream.startCapture()
        } catch {
            self.stream = nil
            throw error
        }
    }

    private func makeStreamConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.sampleRate = 16000
        config.channelCount = 1
        // NOTE: We do NOT use config.captureMicrophone — it's unreliable on macOS 15.
        // Microphone is captured separately via AVAudioEngine below.
        return config
    }

    // MARK: - Microphone Capture (AVAudioEngine)

    private func startMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        let shouldBindExplicitDevice = shouldBindExplicitDevice(microphoneDevice)
        var didBindExplicitDevice = false

        // Set specific device if provided
        if shouldBindExplicitDevice, let device = microphoneDevice {
            let inputNode = engine.inputNode
            if let audioUnit = inputNode.audioUnit {
                var deviceID = device.id
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status == noErr {
                    didBindExplicitDevice = true
                    Log.audio
                        .info(
                            "Meeting mic explicit binding to \(device.name), uid=\(device.uid), transport=\(device.transportType.displayName)"
                        )
                    NSLog("[AudioCapture] Set mic engine device to %@ (id=%d)", device.name, device.id)
                } else {
                    Log.audio
                        .warning(
                            "Meeting mic explicit binding failed: status=\(status), device=\(device.name), uid=\(device.uid)"
                        )
                    NSLog(
                        "[AudioCapture] WARNING: failed to bind mic device %@ (id=%d, status=%d), using system default route",
                        device.name,
                        device.id,
                        status
                    )
                }
            }
        }

        let inputNode = engine.inputNode
        let hardwareInputFormat = inputNode.inputFormat(forBus: 0)
        let tapFormat = inputNode.outputFormat(forBus: 0)

        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw SystemAudioError.microphoneFormatInvalid
        }

        let hardwareFormatDescription = formatDescription(hardwareInputFormat)
        let tapFormatDescription = formatDescription(tapFormat)
        Log.audio.info(
            "Meeting mic format resolved: input=\(hardwareFormatDescription), output=\(tapFormatDescription), explicitBinding=\(didBindExplicitDevice)"
        )
        NSLog(
            "[AudioCapture] Mic input format: sampleRate=%.0f, channels=%d",
            tapFormat.sampleRate,
            tapFormat.channelCount
        )

        // The tap callback delivers buffers in the node's output format.
        // Converting from that format keeps the tap and converter in sync.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw SystemAudioError.microphoneFormatInvalid
        }

        guard let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
            throw SystemAudioError.microphoneFormatInvalid
        }

        micConverter = converter

        // Install tap — runs on audio render thread
        do {
            try ObjCExceptionCatcher.catchException {
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
                    self?.processMicBuffer(buffer)
                }
            }
        } catch {
            let hardwareFormatDescription = formatDescription(hardwareInputFormat)
            let tapFormatDescription = formatDescription(tapFormat)
            Log.audio.error(
                "Meeting mic tap install failed. tapFormat=\(tapFormatDescription), nodeOutputFormat=\(hardwareFormatDescription), error=\(error.localizedDescription)"
            )
            throw SystemAudioError.microphoneStartFailed(
                "Could not start meeting microphone with the current route. Try reconnecting AirPods or choosing System Default."
            )
        }

        try engine.start()
        micEngine = engine
        installMicrophoneObserver(for: engine)

        NSLog("[AudioCapture] AVAudioEngine started for microphone capture")
    }

    private func stopMicrophoneCapture() {
        removeMicrophoneObserver()
        if let engine = micEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            NSLog("[AudioCapture] AVAudioEngine stopped for microphone")
        }
        micEngine = nil
        micConverter = nil
        microphoneCaptureStarted = false
    }

    private func installMicrophoneObserver(for engine: AVAudioEngine) {
        removeMicrophoneObserver()
        micConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleMicrophoneConfigurationChange()
        }
    }

    private func removeMicrophoneObserver() {
        if let observer = micConfigurationObserver {
            NotificationCenter.default.removeObserver(observer)
            micConfigurationObserver = nil
        }
    }

    private func handleMicrophoneConfigurationChange() {
        let currentInputFormat = micEngine?.inputNode.inputFormat(forBus: 0)
        let currentOutputFormat = micEngine?.inputNode.outputFormat(forBus: 0)
        let currentInputDescription = formatDescription(currentInputFormat)
        let currentOutputDescription = formatDescription(currentOutputFormat)
        Log.audio.info(
            "Meeting mic configuration changed - input=\(currentInputDescription), output=\(currentOutputDescription)"
        )

        guard captureMicrophone,
              isCapturing,
              !isStoppingCapture,
              !isRecoveringSystem,
              !isRecoveringMicrophone
        else { return }

        if micEngine?.isRunning == true {
            return
        }

        scheduleMicrophoneRecovery(reason: "configuration change")
    }

    /// Convert mic buffer to 16kHz mono Float32 and dispatch to mixer queue.
    private func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isCapturing, !isStoppingCapture else { return }
        guard let converter = micConverter else { return }

        let inputFormat = buffer.format
        let ratio = 16000.0 / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard outputFrameCapacity > 0 else { return }

        guard let targetFormat = converter.outputFormat as AVAudioFormat?,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity)
        else { return }

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

        guard error == nil, status != .error, outputBuffer.frameLength > 0 else { return }

        guard let channelData = outputBuffer.floatChannelData?[0] else { return }
        let frameCount = Int(outputBuffer.frameLength)
        var samples = [Float](repeating: 0, count: frameCount)
        for i in 0 ..< frameCount {
            samples[i] = channelData[i]
        }

        // Dispatch to mixer queue (same queue as system audio handler)
        mixerQueue.async { [weak self] in
            self?.handleMicrophoneAudio(samples)
        }
    }

    // MARK: - Stop Capture

    /// Synchronously flushes and closes the audio file for the willSleep notification handler.
    ///
    /// Called from a power-management background thread (NOT MainActor). Does NOT stop the
    /// SCStream (that requires async); it only closes the `AVAudioFile` so all buffered audio
    /// is flushed to disk before the system sleeps.
    ///
    /// The `AVAudioFile` close is synchronous (OS file close with header update). The
    /// `synchronizedTeardown` uses `mixerQueue.sync { fileWriteQueue.sync { ... } }` which
    /// drains any in-flight audio buffers before closing. No semaphore needed — already sync.
    ///
    /// Returns the URL of the closed file (or nil if not capturing).
    func synchronousFlushForSleep() -> URL? {
        guard isCapturing else { return nil }
        let url = outputURL
        isStoppingCapture = true
        isCapturing = false
        // Cancel recovery tasks to prevent them from re-opening the stream.
        cancelRecoveryTasks()
        stopMicrophoneCapture()
        // Flush remaining buffers and close AVAudioFile synchronously.
        synchronizedTeardown(flushPendingAudio: true)
        Log.audio.info("[Sleep] synchronousFlushForSleep: file closed at \(url?.path ?? "nil")")
        return url
    }

    func stopCapture() async throws -> URL? {
        guard isCapturing else {
            Log.audio.warning("Not capturing")
            return nil
        }

        isStoppingCapture = true
        cancelRecoveryTasks()

        NSLog(
            "[AudioCapture] Stopping capture... sampleCount=%d, systemBuffers=%d, micBuffers=%d, systemBuf=%d, micBuf=%d",
            sampleCount,
            systemBufferCount,
            micBufferCount,
            systemBuffer.count,
            micBuffer.count
        )

        // Stop microphone first to prevent further mic data arriving
        stopMicrophoneCapture()

        if let stream {
            try await stream.stopCapture()
        }
        stream = nil
        isCapturing = false

        synchronizedTeardown(flushPendingAudio: true)

        let capturedOutputURL = outputURL
        Log.audio.info("Capture stopped, file saved to: \(capturedOutputURL?.path ?? "nil")")
        return capturedOutputURL
    }

    private func cleanupFailedStart(removeOutputFile: Bool) async throws {
        isStoppingCapture = true
        cancelRecoveryTasks()
        stopMicrophoneCapture()

        if let stream {
            try? await stream.stopCapture()
        }

        stream = nil
        isCapturing = false
        synchronizedTeardown(flushPendingAudio: false)

        if removeOutputFile, let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    private func synchronizedTeardown(flushPendingAudio: Bool) {
        mixerQueue.sync { [self] in
            fileWriteQueue.sync { [self] in
                if flushPendingAudio {
                    flushRemainingBuffers()
                }
                audioFile = nil
                outputFormat = nil
                systemBuffer.removeAll()
                micBuffer.removeAll()
            }
        }
        sampleCount = 0
        microphoneCaptureStarted = false
        isRecoveringSystem = false
        isRecoveringMicrophone = false
        isStoppingCapture = false
    }

    private func cancelRecoveryTasks() {
        systemRecoveryTask?.cancel()
        systemRecoveryTask = nil
        microphoneRecoveryTask?.cancel()
        microphoneRecoveryTask = nil
    }

    private func scheduleSystemRecovery(after error: Error) {
        guard isCapturing else { return }
        guard !isStoppingCapture else { return }
        guard !isRecoveringSystem else { return }

        isRecoveringSystem = true
        cancelMicrophoneRecoveryOnly()
        stopMicrophoneCapture()
        dropPendingMixerBuffers()
        stream = nil
        emitStatusMessage("System audio interrupted. Reconnecting…")

        systemRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRecoveringSystem = false
                self.systemRecoveryTask = nil
            }

            for attempt in 1 ... maxSystemRecoveryAttempts {
                if attempt == 1 {
                    try? await Task.sleep(for: .seconds(initialRecoveryDelay))
                } else {
                    try? await Task.sleep(for: .seconds(recoveryDelay(for: attempt)))
                }

                guard !Task.isCancelled, isCapturing, !isStoppingCapture else { return }

                do {
                    try await createAndStartSystemStream()
                    Log.audio.info("System audio recovered on attempt \(attempt)")

                    if captureMicrophone {
                        do {
                            try startMicrophoneCapture()
                            microphoneCaptureStarted = true
                        } catch {
                            Log.audio.warning(
                                "Microphone restart after system recovery failed: \(error.localizedDescription)"
                            )
                            scheduleMicrophoneRecovery(
                                reason: "system audio recovered",
                                allowDuringSystemRecovery: true
                            )
                        }
                    }

                    emitStatusMessage("System audio reconnected")
                    return
                } catch {
                    Log.audio.warning(
                        "System audio recovery attempt \(attempt) failed: \(error.localizedDescription)"
                    )
                }
            }

            let recoveryError = SystemAudioError.streamRecoveryFailed(
                "System audio capture was interrupted and could not reconnect."
            )
            failCapture(recoveryError)
        }
    }

    private func scheduleMicrophoneRecovery(
        reason: String,
        allowDuringSystemRecovery: Bool = false
    ) {
        guard captureMicrophone,
              isCapturing,
              !isStoppingCapture,
              !isRecoveringSystem || allowDuringSystemRecovery,
              !isRecoveringMicrophone
        else { return }

        isRecoveringMicrophone = true
        stopMicrophoneCapture()
        dropPendingMixerBuffers()
        emitStatusMessage("Microphone changed. Reconnecting…")

        microphoneRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRecoveringMicrophone = false
                self.microphoneRecoveryTask = nil
            }

            var triedDefaultFallback = false

            for attempt in 1 ... maxMicrophoneRecoveryAttempts {
                try? await Task.sleep(for: .seconds(recoveryDelay(for: attempt)))
                guard !Task.isCancelled, isCapturing, !isStoppingCapture else { return }

                do {
                    try startMicrophoneCapture()
                    microphoneCaptureStarted = true
                    Log.audio.info("Microphone recovered after \(reason) on attempt \(attempt)")
                    emitStatusMessage("Microphone reconnected")
                    return
                } catch {
                    Log.audio.warning(
                        "Microphone recovery attempt \(attempt) after \(reason) failed: \(error.localizedDescription)"
                    )

                    if !triedDefaultFallback, microphoneDevice != nil {
                        let failedDeviceName = microphoneDevice?.name ?? "selected microphone"
                        microphoneDevice = nil
                        triedDefaultFallback = true
                        emitStatusMessage("\(failedDeviceName) unavailable. Using System Default…")
                    }
                }
            }

            captureMicrophone = false
            emitStatusMessage("Microphone unavailable. Continuing with system audio")
        }
    }

    private func recoveryDelay(for attempt: Int) -> TimeInterval {
        initialRecoveryDelay * pow(2.0, Double(max(0, attempt - 1)))
    }

    private func emitStatusMessage(_ message: String) {
        Log.audio.info("\(message)")
        onStatusMessage?(message)
    }

    private func dropPendingMixerBuffers() {
        mixerQueue.sync {
            systemBuffer.removeAll()
            micBuffer.removeAll()
        }
    }

    private func cancelMicrophoneRecoveryOnly() {
        microphoneRecoveryTask?.cancel()
        microphoneRecoveryTask = nil
        isRecoveringMicrophone = false
    }

    private func failCapture(_ error: Error) {
        stopMicrophoneCapture()
        stream = nil
        isCapturing = false
        synchronizedTeardown(flushPendingAudio: false)
        onError?(error)
    }

    // MARK: - Audio File Setup

    private func setupAudioFile(at url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        outputFormat = AVAudioFormat(settings: settings)
        audioFile = try AVAudioFile(forWriting: url, settings: settings)
        Log.audio.info("Audio file created at: \(url.path) (16kHz mono 16-bit)")
    }

    // MARK: - Flush on Stop

    /// Flush any remaining buffered audio directly to file.
    /// IMPORTANT: Called from `fileWriteQueue.sync` inside `mixerQueue.sync` —
    /// must NOT dispatch to either queue (would deadlock or drop data).
    /// Pass `allowRotation: false` to keep the final flush in a single chunk.
    private func flushRemainingBuffers() {
        guard audioFile != nil else { return }

        if captureMicrophone {
            // Mix overlapping frames synchronously and write to file only.
            let mixCount = min(systemBuffer.count, micBuffer.count)
            if mixCount > 0 {
                var mixed = [Float](repeating: 0, count: mixCount)
                for i in 0 ..< mixCount {
                    mixed[i] = max(-1.0, min(1.0, systemBuffer[i] + micBuffer[i]))
                }
                systemBuffer.removeFirst(mixCount)
                micBuffer.removeFirst(mixCount)
                writeSamples(mixed, allowRotation: false)
            }
            if !systemBuffer.isEmpty {
                writeSamples(systemBuffer, allowRotation: false)
                systemBuffer.removeAll()
            }
            if !micBuffer.isEmpty {
                writeSamples(micBuffer, allowRotation: false)
                micBuffer.removeAll()
            }
        } else if !systemBuffer.isEmpty {
            writeSamples(systemBuffer, allowRotation: false)
            systemBuffer.removeAll()
        }
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let activeStream = self.stream, activeStream === stream, isCapturing, !isStoppingCapture else { return }
        Log.audio.error("Stream stopped with error: \(error)")
        scheduleSystemRecovery(after: error)
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCaptureService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let activeStream = self.stream, activeStream === stream, isCapturing, !isStoppingCapture else { return }
        delegateCallCount += 1
        if delegateCallCount <= 5 {
            NSLog("[AudioCapture] delegate called #%d, type=%d (.screen=0, .audio=1)", delegateCallCount, type.rawValue)
        }
        guard type == .audio else { return }

        let samples = extractFloatSamples(from: sampleBuffer)
        guard let samples, !samples.isEmpty else { return }

        sampleCount += 1

        // Dispatch system audio to mixer queue
        mixerQueue.async { [weak self] in
            self?.handleSystemAudio(samples)
        }
    }

    // MARK: - Source Handlers (called on mixerQueue)

    private func handleSystemAudio(_ samples: [Float]) {
        systemBufferCount += 1
        if systemBufferCount <= 3 || systemBufferCount % 500 == 0 {
            NSLog(
                "[AudioCapture] .audio buffer #%d, %d samples (mic buffers so far: %d)",
                systemBufferCount,
                samples.count,
                micBufferCount
            )
        }

        if rms(samples) > silenceRMSThreshold {
            lastNonSilentSystemTime = Date()
            didFireSystemSilent = false
        } else {
            checkSilence(source: .system)
        }

        if captureMicrophone {
            let appliedSystemGain = systemGain
            let gained = samples.map { max(-1, min(1, $0 * appliedSystemGain)) }
            systemBuffer.append(contentsOf: gained)
            drainMixedSamples()
            flushStaleBuffer()
        } else {
            emitRealtimeData(samples)
            fileWriteQueue.async { [weak self] in
                self?.writeSamples(samples)
            }
        }
    }

    private func handleMicrophoneAudio(_ samples: [Float]) {
        micBufferCount += 1
        if micBufferCount <= 3 || micBufferCount % 500 == 0 {
            NSLog(
                "[AudioCapture] .microphone buffer #%d, %d samples (sys buffers so far: %d)",
                micBufferCount,
                samples.count,
                systemBufferCount
            )
        }

        if rms(samples) > silenceRMSThreshold {
            lastNonSilentMicTime = Date()
            didFireMicSilent = false
        } else {
            checkSilence(source: .microphone)
        }

        let gained = samples.map { max(-1, min(1, $0 * micGain)) }
        micBuffer.append(contentsOf: gained)
        drainMixedSamples()
        flushStaleBuffer()
    }

    // MARK: - Inline Mixer (called on mixerQueue)

    private func drainMixedSamples() {
        let mixCount = min(systemBuffer.count, micBuffer.count)
        guard mixCount > 0 else { return }

        var mixed = [Float](repeating: 0, count: mixCount)
        for i in 0 ..< mixCount {
            mixed[i] = max(-1.0, min(1.0, systemBuffer[i] + micBuffer[i]))
        }
        systemBuffer.removeFirst(mixCount)
        micBuffer.removeFirst(mixCount)

        emitRealtimeData(mixed)
        fileWriteQueue.async { [weak self] in
            self?.writeSamples(mixed)
        }
    }

    /// Flush any single-source buffer that has accumulated beyond the threshold.
    /// This prevents audio from being held indefinitely when one source delivers
    /// faster or the other is temporarily silent.
    private func flushStaleBuffer() {
        flushIfStale(&systemBuffer, emitRealtime: captureMicrophone)
        flushIfStale(&micBuffer, emitRealtime: captureMicrophone)
    }

    private func flushIfStale(_ buffer: inout [Float], emitRealtime: Bool) {
        guard buffer.count > flushThresholdFrames else { return }
        let stale = Array(buffer)
        buffer.removeAll()
        if emitRealtime {
            emitRealtimeData(stale)
        }
        fileWriteQueue.async { [weak self] in
            self?.writeSamples(stale)
        }
    }

    // MARK: - Real-Time Streaming

    private func emitRealtimeData(_ samples: [Float]) {
        guard let onRawAudioData else { return }

        var data = Data(count: samples.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0 ..< samples.count {
                int16Buffer[i] = Int16(max(-1.0, min(1.0, samples[i])) * Float(Int16.max))
            }
        }

        rawAudioCallbackCount += 1
        if rawAudioCallbackCount <= 5 || rawAudioCallbackCount % 200 == 0 {
            NSLog("[AudioCapture] onRawAudioData #%d, %d bytes", rawAudioCallbackCount, data.count)
        }

        realtimeQueue.async {
            onRawAudioData(data)
        }
    }

    // MARK: - File Writing

    /// Write Float samples to the audio file. AVAudioFile accepts Float32 buffers matching
    /// its `processingFormat` and internally converts to the file's Int16 format.
    ///
    /// When `allowRotation` is true (default), checks the 5-min boundary after writing and
    /// rotates to the next chunk if `chunkURLProvider` is set. Teardown paths
    /// (`flushRemainingBuffers`) pass `allowRotation: false` to keep the final flush
    /// in a single chunk file.
    private func writeSamples(_ samples: [Float], allowRotation: Bool = true) {
        guard let audioFile else { return }

        let processingFormat = audioFile.processingFormat

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        guard let channelData = buffer.floatChannelData?[0] else { return }
        for i in 0 ..< samples.count {
            channelData[i] = samples[i]
        }

        do {
            try audioFile.write(from: buffer)
            currentChunkFrameCount += samples.count

            let now = Date()
            let currentFlushInterval = flushInterval
            if now.timeIntervalSince(lastFlushTime) >= currentFlushInterval {
                Log.audio.info("Audio buffer auto-flush (every \(currentFlushInterval)s)")
                lastFlushTime = now
            }
        } catch {
            Log.audio.error("Error writing audio: \(error)")
        }

        if allowRotation {
            rotateChunkIfNeededOnFileWriteQueue()
        }
    }

    // MARK: - Chunk Rotation (RLR-M3b)

    /// Closes the current chunk and opens the next one when wall-clock elapsed since
    /// chunk-open exceeds `chunkDurationSeconds`. Must only be called on `fileWriteQueue`.
    ///
    /// No-op when `chunkURLProvider` is nil (legacy single-file mode).
    private func rotateChunkIfNeededOnFileWriteQueue() {
        guard let provider = chunkURLProvider else { return }
        guard audioFile != nil else { return }
        let elapsed = Date().timeIntervalSince(currentChunkStartedAt)
        guard elapsed >= chunkDurationSeconds else { return }

        let closedIndex = currentChunkIndex
        guard let closedURL = outputURL else { return }
        let closedAt = Date()
        let closedFrameCount = currentChunkFrameCount
        let sampleRate = outputFormat?.sampleRate ?? 16000
        let durationSeconds = sampleRate > 0 ? Double(closedFrameCount) / sampleRate : 0

        // Close current AVAudioFile — write of header trailer happens on dealloc.
        // AVAudioFile close is synchronous; rotation gap is sub-ms (PoC: no-writer p95 = 6.0 ms).
        audioFile = nil

        var byteCount: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: closedURL.path),
           let size = attrs[.size] as? Int64
        {
            byteCount = size
        }

        let newIndex = closedIndex + 1
        let newURL = provider(newIndex)
        do {
            try setupAudioFile(at: newURL)
            outputURL = newURL
            currentChunkIndex = newIndex
            currentChunkStartedAt = Date()
            currentChunkFrameCount = 0

            Log.audio.info(
                "[ChunkRotate] closed chunk \(closedIndex) (\(byteCount) B, \(String(format: "%.1f", durationSeconds))s); opened chunk \(newIndex) at \(newURL.lastPathComponent)"
            )

            onChunkRotated?(closedIndex, closedURL, closedAt, byteCount, durationSeconds)
        } catch {
            Log.audio
                .error(
                    "[ChunkRotate] FAILED to open chunk \(newIndex) at \(newURL.path): \(error.localizedDescription)"
                )
            // Recording is now broken — subsequent writeSamples will drop because audioFile is nil.
            // Surface to caller so it can transition state and persist whatever chunks already closed.
            onError?(SystemAudioError.chunkRotationFailed(error.localizedDescription))
        }
    }

    // MARK: - Sample Extraction

    private func extractFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer, totalLength > 0 else { return nil }

        let channelCount = max(1, Int(asbd.pointee.mChannelsPerFrame))
        let bitsPerChannel = Int(asbd.pointee.mBitsPerChannel)
        let bytesPerSample = max(1, bitsPerChannel / 8)
        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)

        let frameCount: Int
        if isNonInterleaved {
            frameCount = totalLength / (channelCount * bytesPerSample)
        } else if bytesPerFrame > 0 {
            frameCount = totalLength / bytesPerFrame
        } else {
            return nil
        }
        guard frameCount > 0 else { return nil }

        let currentSampleCount = sampleCount
        if currentSampleCount <= 3 {
            Log.audio
                .info(
                    "Audio sample \(currentSampleCount): frames=\(frameCount), sampleRate=\(asbd.pointee.mSampleRate), ch=\(channelCount), bits=\(bitsPerChannel), float=\(isFloat)"
                )
        }

        let rawPointer = UnsafeRawPointer(ptr)

        func sample(at offset: Int) -> Float {
            if isFloat, bitsPerChannel == 32 {
                var value: Float = 0
                memcpy(&value, rawPointer.advanced(by: offset), MemoryLayout<Float>.size)
                return value
            }
            if !isFloat, bitsPerChannel == 16 {
                var value: Int16 = 0
                memcpy(&value, rawPointer.advanced(by: offset), MemoryLayout<Int16>.size)
                return Float(value) / Float(Int16.max)
            }
            if !isFloat, bitsPerChannel == 32 {
                var value: Int32 = 0
                memcpy(&value, rawPointer.advanced(by: offset), MemoryLayout<Int32>.size)
                return Float(value) / Float(Int32.max)
            }
            return 0
        }

        var result = [Float](repeating: 0, count: frameCount)
        for frame in 0 ..< frameCount {
            var mixed: Float = 0
            for channel in 0 ..< channelCount {
                let offset: Int = if isNonInterleaved {
                    (channel * frameCount + frame) * bytesPerSample
                } else {
                    (frame * channelCount + channel) * bytesPerSample
                }
                mixed += sample(at: offset)
            }
            result[frame] = mixed / Float(channelCount)
        }

        return result
    }

    // MARK: - Silence Detection

    private enum SilenceSource { case system, microphone }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }

    private func checkSilence(source: SilenceSource) {
        let now = Date()
        switch source {
        case .system:
            if !didFireSystemSilent, now.timeIntervalSince(lastNonSilentSystemTime) > silenceTimeout {
                didFireSystemSilent = true
                let callback = onSystemAudioSilent
                DispatchQueue.main.async { callback?() }
            }
        case .microphone:
            if !didFireMicSilent, now.timeIntervalSince(lastNonSilentMicTime) > silenceTimeout {
                didFireMicSilent = true
                let callback = onMicrophoneSilent
                DispatchQueue.main.async { callback?() }
            }
        }
    }

    private func shouldBindExplicitDevice(_ device: AudioDevice?) -> Bool {
        guard let device else { return false }
        return !device.isDefault
    }

    private func formatDescription(_ format: AVAudioFormat?) -> String {
        guard let format else { return "nil" }
        return "\(format.channelCount)ch @ \(Int(format.sampleRate))Hz \(commonFormatDescription(format.commonFormat))"
    }

    private func commonFormatDescription(_ format: AVAudioCommonFormat) -> String {
        switch format {
        case .otherFormat:
            "other"
        case .pcmFormatFloat32:
            "Float32"
        case .pcmFormatFloat64:
            "Float64"
        case .pcmFormatInt16:
            "Int16"
        case .pcmFormatInt32:
            "Int32"
        @unknown default:
            "unknown"
        }
    }
}

// MARK: - Errors

enum SystemAudioError: LocalizedError {
    case noDisplayFound
    case streamCreationFailed
    case streamRecoveryFailed(String)
    case permissionDenied
    case microphoneFormatInvalid
    case microphoneStartFailed(String)
    case chunkRotationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            "No display found for screen capture"
        case .streamCreationFailed:
            "Failed to create audio capture stream"
        case let .streamRecoveryFailed(reason):
            reason
        case .permissionDenied:
            "Screen recording permission required"
        case .microphoneFormatInvalid:
            "Invalid microphone audio format"
        case let .microphoneStartFailed(reason):
            reason
        case let .chunkRotationFailed(reason):
            "Failed to rotate recording chunk: \(reason)"
        }
    }
}
