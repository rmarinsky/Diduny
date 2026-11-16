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
            String(
                localized: "This may indicate an audio device issue. Please try again or select a different microphone."
            )
    }
}

@MainActor
final class AudioRecorderService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var audioLevel: Float = 0

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var configurationObserver: NSObjectProtocol?
    private var realtimeAudioStreamer: RealtimeAudioStreamer?
    private var activeRecordingFormat: AVAudioFormat?
    private nonisolated let _audioLevelBox = OSAllocatedUnfairLock<Float>(initialState: 0)
    private var audioLevelTimer: DispatchSourceTimer?
    private(set) var currentRecordingDeviceInfo: RecordingDeviceInfo?
    /// While a start awaits the engine queue, only the start path may touch the engine.
    private var isStartingEngine = false

    /// Timeout for audio hardware operations (in seconds)
    /// Increased to 5s to support older Intel Macs which can be slower
    private let audioOperationTimeout: TimeInterval = 5.0

    /// Returns the current recording file path, if recording
    var currentRecordingPath: String? {
        recordingURL?.path
    }

    /// Real-time PCM stream in `s16le`, 16kHz, mono for cloud websocket transcription/translation.
    var onRealtimeAudioData: ((Data) -> Void)?

    /// Same 16 kHz PCM stream for on-device analysis (silence auto-stop). Snapshotted at start, like
    /// `onRealtimeAudioData`.
    var onAnalysisAudioData: ((Data) -> Void)?

    /// Called when the recording device is lost mid-recording (engine failed to restart).
    var onDeviceLost: (() -> Void)?

    // MARK: - Public Methods

    func startRecording(device: AudioDevice?) async throws {
        let recordingInProgress = isRecording
        Log.audio.info("startRecording: BEGIN, isRecording=\(recordingInProgress)")
        currentRecordingDeviceInfo = nil
        guard !recordingInProgress else {
            Log.audio.warning("startRecording: Already recording, returning")
            return
        }
        #if TEST_BUILD
            // Fake input (test-plan 2.2): no device, no permission, steady level 0.5.
            if UITestHarness.usesFakeAudio {
                isRecording = true
                audioLevel = 0.5
                return
            }
        #endif

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
        isStartingEngine = true
        defer { isStartingEngine = false }

        // Set up input device on the engine
        // IMPORTANT: Accessing engine.inputNode can hang indefinitely if CoreAudio/coreaudiod is unresponsive
        // We wrap this in a timeout to prevent the app from freezing
        let shouldBindExplicitDevice = shouldBindExplicitDevice(device)
        // The cached device ID goes stale when a device reconnects, so look it up again by UID.
        let deviceUID = shouldBindExplicitDevice ? device?.uid : nil
        let hardwareInputFormat: AVAudioFormat
        let tapFormat: AVAudioFormat
        let inputNode: AVAudioInputNode
        let audioOperationTimeout = audioOperationTimeout
        // One queue per engine: a call that hangs blocks only this engine, not the fallback's.
        let engineQueue = DispatchQueue(label: "ua.com.rmarinsky.diduny.audio-engine", qos: .userInitiated)

        do {
            Log.audio.info("startRecording: Initializing audio engine with \(audioOperationTimeout)s timeout")

            // Run audio hardware initialization with timeout to prevent hanging
            let result = try await Self.runWithTimeout(
                on: engineQueue,
                operation: "audio engine initialization",
                timeout: audioOperationTimeout
            ) { [engine] () throws -> (AVAudioInputNode, AVAudioFormat, AVAudioFormat) in
                // Set device on the audio unit if specified
                if let deviceUID {
                    guard let deviceID = Self.currentDeviceID(forUID: deviceUID) else {
                        throw AudioError.recordingFailed("Microphone \(deviceUID) is no longer connected")
                    }
                    let node = engine.inputNode
                    if let audioUnit = node.audioUnit {
                        var mutableDeviceID = deviceID
                        let status = AudioUnitSetProperty(
                            audioUnit,
                            kAudioOutputUnitProperty_CurrentDevice,
                            kAudioUnitScope_Global,
                            0,
                            &mutableDeviceID,
                            UInt32(MemoryLayout<AudioDeviceID>.size)
                        )
                        guard status == noErr else {
                            throw AudioError.recordingFailed("Could not select microphone (OSStatus \(status))")
                        }
                    }
                }

                // Access inputNode - this is where the hang typically occurs
                let node = engine.inputNode
                let hardwareInputFormat = node.inputFormat(forBus: 0)
                let tapFormat = node.outputFormat(forBus: 0)
                return (node, hardwareInputFormat, tapFormat)
            }

            inputNode = result.0
            hardwareInputFormat = result.1
            tapFormat = result.2
            Log.audio.info("startRecording: Audio engine initialized successfully")
        } catch let error as AudioTimeoutError {
            Log.audio.error("startRecording: \(error.localizedDescription)")
            if audioEngine === engine { audioEngine = nil }
            // The hung call still owns the engine; tear it down after it returns.
            engineQueue.async { engine.stop(); engine.reset() }
            throw AudioError.recordingFailed(error.localizedDescription)
        } catch {
            Log.audio.error("startRecording: engine initialization failed: \(error.localizedDescription)")
            if audioEngine === engine { audioEngine = nil }
            throw error
        }

        // cancelRecording() (or a newer start) may have run during the await above.
        // Starting this engine now would leave the mic on with nothing able to stop it.
        guard audioEngine === engine else {
            Log.audio.warning("startRecording: canceled during engine initialization")
            throw CancellationError()
        }

        if let device {
            Log.audio.info(
                "startRecording: Resolved device = \(device.name), transport=\(device.transportType.rawValue), sampleRate=\(Int(device.sampleRate)), uid=\(device.uid), explicitBinding=\(shouldBindExplicitDevice)"
            )
        } else {
            Log.audio.info("startRecording: Resolved device = System Default")
        }
        let hardwareInputFormatDescription = formatDescription(hardwareInputFormat)
        let outputFormatDescription = formatDescription(tapFormat)
        Log.audio.info("startRecording: Hardware input format = \(hardwareInputFormatDescription)")
        Log.audio.info("startRecording: Input node output format = \(outputFormatDescription)")
        currentRecordingDeviceInfo = makeRecordingDeviceInfo(device: device, inputFormat: tapFormat)

        // The input node tap records from the node's output bus, not its hardware input bus.
        // Using the tap/output format avoids mismatches that can prevent recording from starting.
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            Log.audio
                .error(
                    "startRecording: Invalid tap format - sampleRate=\(tapFormat.sampleRate), channels=\(tapFormat.channelCount)"
                )
            audioEngine = nil
            throw AudioError
                .recordingFailed("Invalid audio format. Please try selecting a different microphone in Settings.")
        }

        // Keep in-flight audio under Application Support so crash recovery does not
        // depend on the lifecycle of the system temporary directory.
        recordingURL = RecoveryStateManager.shared.makeRecordingURL()
        let recordingPath = recordingURL?.path ?? "nil"
        Log.audio.info("startRecording: Recording URL = \(recordingPath)")

        guard let url = recordingURL else {
            Log.audio.error("startRecording: Failed to create URL")
            throw AudioError.recordingFailed("Could not create recording file")
        }

        // Write the file as 16 kHz mono Int16 (what transcription needs) instead of the mic's
        // native format, which is ~8x larger.
        guard let fileConverter = Mono16kConverter(inputFormat: tapFormat) else {
            Log.audio.error("startRecording: Failed to create 16 kHz converter for \(outputFormatDescription)")
            audioEngine = nil
            throw AudioError.recordingFailed("Could not create audio converter")
        }

        do {
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: Mono16kConverter.outputFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            Log.audio.error("startRecording: Failed to create audio file: \(error.localizedDescription)")
            throw AudioError.recordingFailed("Could not create audio file: \(error.localizedDescription)")
        }

        Log.audio.info("startRecording: Audio file created as 16kHz mono Int16")

        // Capture file reference for use in tap callback (runs on audio thread)
        guard let file = audioFile else {
            throw AudioError.recordingFailed("Audio file not initialized")
        }

        // Optional realtime streamer for websocket mode (translation/live features)
        let realtimeAudioStreamer = makeRealtimeAudioStreamerIfNeeded(inputFormat: tapFormat)
        self.realtimeAudioStreamer = realtimeAudioStreamer
        activeRecordingFormat = tapFormat

        // Install tap on input node to capture audio
        // IMPORTANT: This callback runs on a realtime audio thread, NOT the main thread
        // NOTE: installTap is synchronous and must be called on the main thread.
        // Do NOT wrap this in withAudioTimeout as it causes threading issues on Intel Macs.
        Log.audio.info("startRecording: Installing tap on input node...")
        do {
            try ObjCExceptionCatcher.catchException {
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
                    // Update audio level from buffer (thread-safe method)
                    self?.updateAudioLevelFromBuffer(buffer)

                    do {
                        if let converted = fileConverter.convert(buffer) {
                            try file.write(from: converted)
                        }
                    } catch {
                        Log.audio.error("Failed to write audio buffer: \(error.localizedDescription)")
                    }

                    realtimeAudioStreamer?.process(buffer: buffer)
                }
            }
        } catch {
            let tapFormatDescription = formatDescription(tapFormat)
            let nodeOutputFormatDescription = formatDescription(hardwareInputFormat)
            Log.audio.error(
                "startRecording: Failed to install tap. tapFormat=\(tapFormatDescription), nodeOutputFormat=\(nodeOutputFormatDescription), error=\(error.localizedDescription)"
            )
            cleanupAfterFailedStart(removeTap: false, removeFile: true)
            throw AudioError.recordingFailed(
                "Could not start recording with the current microphone route. Try reconnecting AirPods or reselecting the microphone in Settings."
            )
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

        // Start the engine on its own queue with a timeout: a mic that does not answer
        // must not freeze the main thread, and the caller falls back to the next mic.
        do {
            Log.audio.info("startRecording: Starting audio engine...")
            let isRunning = try await Self.runWithTimeout(
                on: engineQueue,
                operation: "audio engine start",
                timeout: audioOperationTimeout
            ) { [engine] () throws -> Bool in
                try engine.start()
                return engine.isRunning
            }
            Log.audio.info("startRecording: Audio engine started")

            guard audioEngine === engine else {
                Log.audio.warning("startRecording: canceled during engine start")
                engineQueue.async { inputNode.removeTap(onBus: 0); engine.stop(); engine.reset() }
                cleanupAfterFailedStart(removeTap: false, removeFile: true)
                throw CancellationError()
            }

            // Verify engine is actually running
            guard isRunning else {
                Log.audio.error("startRecording: Engine started but isRunning=false")
                inputNode.removeTap(onBus: 0)
                throw AudioError.recordingFailed("Audio engine failed to start. Please try a different microphone.")
            }
            Log.audio.info("startRecording: Engine verified running")
        } catch let error as CancellationError {
            throw error
        } catch let error as AudioTimeoutError {
            Log.audio.error("startRecording: \(error.localizedDescription)")
            // engine.start() is still blocked on engineQueue: do not touch the engine from here.
            if audioEngine === engine { audioEngine = nil }
            engineQueue.async { inputNode.removeTap(onBus: 0); engine.stop(); engine.reset() }
            cleanupAfterFailedStart(removeTap: false, removeFile: true)
            throw AudioError.recordingFailed(error.localizedDescription)
        } catch {
            Log.audio.error("startRecording: Failed to start engine: \(error.localizedDescription)")
            cleanupAfterFailedStart(removeTap: true, removeFile: true)
            throw AudioError.recordingFailed("Failed to start audio engine: \(error.localizedDescription)")
        }

        isRecording = true
        startAudioLevelPolling()
        let updatedRecordingState = isRecording
        Log.audio.info("startRecording: END, isRecording=\(updatedRecordingState)")
    }

    /// Stop path for realtime sessions: wait for the tap buffer that was filling
    /// when Stop was pressed (at most `timeout`), then for its conversion, so the
    /// last spoken audio is on the socket before the end-of-stream frame.
    func flushRealtimeAudio(timeout: Duration = .milliseconds(100)) async {
        await realtimeAudioStreamer?.flush(timeout: timeout)
    }

    func stopRecording() async throws -> Data {
        #if TEST_BUILD
            if UITestHarness.usesFakeAudio, isRecording, audioEngine == nil {
                isRecording = false
                audioLevel = 0
                return UITestHarness.silentWAV()
            }
        #endif
        let recordingInProgress = isRecording
        Log.audio.info("stopRecording: BEGIN, isRecording=\(recordingInProgress)")
        guard isRecording, let engine = audioEngine, let url = recordingURL else {
            let logMsg = "stopRecording: No active recording! isRecording=\(recordingInProgress), " +
                "engine=\(audioEngine != nil), url=\(recordingURL?.path ?? "nil")"
            Log.audio.warning("\(logMsg)")
            throw AudioError.recordingFailed("No active recording")
        }

        Log.audio.info("stopRecording: Removing tap and stopping engine")

        // Remove tap and stop engine
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        // Remove configuration observer
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }

        // Close the audio file
        audioFile = nil

        isRecording = false
        stopAudioLevelPolling()
        onDeviceLost = nil
        activeRecordingFormat = nil

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
        #if TEST_BUILD
            if UITestHarness.usesFakeAudio, audioEngine == nil {
                isRecording = false
                audioLevel = 0
                return
            }
        #endif
        guard let engine = audioEngine else { return }
        if isStartingEngine {
            // startRecording sees the nil engine after its await and cleans up on the engine queue.
            audioEngine = nil
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }

        audioFile = nil
        audioEngine = nil
        activeRecordingFormat = nil

        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }

        realtimeAudioStreamer = nil
        isRecording = false
        stopAudioLevelPolling()
        currentRecordingDeviceInfo = nil
        onDeviceLost = nil
    }

    // MARK: - Private Methods

    private func handleConfigurationChange() {
        let currentInputFormat = audioEngine?.inputNode.inputFormat(forBus: 0)
        let currentOutputFormat = audioEngine?.inputNode.outputFormat(forBus: 0)
        let currentInputFormatDescription = formatDescription(currentInputFormat)
        let currentOutputFormatDescription = formatDescription(currentOutputFormat)
        Log.audio.info(
            "Audio configuration changed - input=\(currentInputFormatDescription), output=\(currentOutputFormatDescription)"
        )

        guard isRecording, let engine = audioEngine else { return }

        // The engine is automatically stopped on configuration changes.
        // Try to restart it; if that fails the device is likely gone.
        if !engine.isRunning {
            do {
                try engine.start()
                Log.audio.info("Audio engine restarted after configuration change")
            } catch {
                Log.audio.error("Failed to restart engine after config change: \(error.localizedDescription)")
                onDeviceLost?()
            }
        }
    }

    private func cleanupAfterFailedStart(removeTap: Bool, removeFile: Bool) {
        if removeTap, let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
        }

        audioEngine?.stop()
        audioEngine?.reset()

        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }

        audioFile = nil
        realtimeAudioStreamer = nil
        activeRecordingFormat = nil
        currentRecordingDeviceInfo = nil
        isRecording = false
        stopAudioLevelPolling()
        onDeviceLost = nil

        if removeFile, let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }

        audioEngine = nil
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

    private nonisolated func updateAudioLevelFromBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        for i in 0 ..< frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        let db = 20 * log10(max(rms, 0.0001))
        let minDb: Float = -60
        let normalizedLevel = max(0, min(1, (db - minDb) / -minDb))

        _audioLevelBox.withLock { $0 = normalizedLevel }
    }

    private func startAudioLevelPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 25.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let latest = _audioLevelBox.withLock { $0 }
            if abs(latest - audioLevel) > 0.01 {
                audioLevel = latest
            }
        }
        timer.resume()
        audioLevelTimer = timer
    }

    private func stopAudioLevelPolling() {
        audioLevelTimer?.cancel()
        audioLevelTimer = nil
        audioLevel = 0
    }

    // MARK: - Timeout Helper

    /// Runs blocking audio work on `queue` and returns after `timeout` even if the work is still
    /// blocked. A task group cannot do this: it waits for every child, including a hung one.
    nonisolated static func runWithTimeout<T>(
        on queue: DispatchQueue,
        operation: String,
        timeout: TimeInterval,
        work: @escaping () throws -> T
    ) async throws -> T {
        let finished = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            let finish: (Result<T, Error>) -> Void = { result in
                let isFirst = finished.withLock { done in
                    defer { done = true }
                    return !done
                }
                if isFirst { continuation.resume(with: result) }
            }
            queue.async { finish(Result { try work() }) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(AudioTimeoutError(operation: operation, timeout: timeout)))
            }
        }
    }

    /// Looks the device up again by UID: a device that reconnects (iPhone, AirPods) gets a new ID.
    private nonisolated static func currentDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func makeRealtimeAudioStreamerIfNeeded(inputFormat: AVAudioFormat) -> RealtimeAudioStreamer? {
        let realtime = onRealtimeAudioData
        let analysis = onAnalysisAudioData
        guard realtime != nil || analysis != nil else { return nil }
        return RealtimeAudioStreamer(inputFormat: inputFormat) { data in
            realtime?(data)
            analysis?(data)
        }
    }

    private func makeRecordingDeviceInfo(device: AudioDevice?, inputFormat: AVAudioFormat) -> RecordingDeviceInfo? {
        guard let device else { return nil }
        return RecordingDeviceInfo(
            uid: device.uid,
            name: device.name,
            transportType: device.transportType.displayName,
            sampleRate: inputFormat.sampleRate,
            channelCount: Int(inputFormat.channelCount),
            wasDefaultRoute: device.isDefault
        )
    }
}

/// Converts mic buffers to 16 kHz mono Int16, the format of the recording file and the realtime stream.
/// Stateful (keeps resampler history between buffers), so use one instance per stream from one thread.
final class Mono16kConverter {
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    private let converter: AVAudioConverter

    init?(inputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            return nil
        }
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let outputFormat = Self.outputFormat
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
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
                Log.audio.error("Mono16kConverter conversion error: \(error.localizedDescription)")
            }
            return nil
        }

        return outputBuffer
    }
}

private final class RealtimeAudioStreamer {
    private let queue = DispatchQueue(label: "ua.com.rmarinsky.diduny.realtime.mic", qos: .userInitiated)
    private let converter: Mono16kConverter
    private let onAudioData: (Data) -> Void

    init?(inputFormat: AVAudioFormat, onAudioData: @escaping (Data) -> Void) {
        guard let converter = Mono16kConverter(inputFormat: inputFormat) else {
            return nil
        }

        self.converter = converter
        self.onAudioData = onAudioData
    }

    private let lock = NSLock()
    private var nextBufferWaiters: [() -> Void] = []

    func process(buffer: AVAudioPCMBuffer) {
        guard let copiedBuffer = copyBuffer(buffer) else { return }

        queue.async { [weak self] in
            guard let self else { return }
            if let data = convertToRealtimePCM(buffer: copiedBuffer) { onAudioData(data) }
            resumeWaiters()
        }
    }

    /// Returns once the next tap buffer is converted and delivered, or after `timeout`.
    func flush(timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OSAllocatedUnfairLock(initialState: false)
            let resume = {
                let first = once.withLock { done in defer { done = true }; return !done }
                if first { continuation.resume() }
            }
            lock.lock(); nextBufferWaiters.append(resume); lock.unlock()
            let ms = Int(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
            queue.asyncAfter(deadline: .now() + .milliseconds(ms), execute: resume)
        }
    }

    private func resumeWaiters() {
        lock.lock(); let waiters = nextBufferWaiters; nextBufferWaiters.removeAll(); lock.unlock()
        waiters.forEach { $0() }
    }

    private func convertToRealtimePCM(buffer: AVAudioPCMBuffer) -> Data? {
        guard let outputBuffer = converter.convert(buffer) else { return nil }

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
