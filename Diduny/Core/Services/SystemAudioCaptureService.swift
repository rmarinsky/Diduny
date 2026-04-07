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
    private var outputFormat: AVAudioFormat?
    private var sampleCount: Int = 0
    private var lastFlushTime: Date = .init()
    private let flushInterval: TimeInterval = 30.0

    // Microphone capture via AVAudioEngine (SCStream's captureMicrophone is unreliable)
    private var micEngine: AVAudioEngine?
    private var micConverter: AVAudioConverter?

    private let realtimeQueue = DispatchQueue(label: "ua.com.rmarinsky.diduny.realtime", qos: .userInitiated)
    private let fileWriteQueue = DispatchQueue(label: "ua.com.rmarinsky.diduny.systemaudio.write")
    /// Serial queue for mixer buffer access — both SCStream callbacks and AVAudioEngine tap dispatch here.
    private let mixerQueue = DispatchQueue(label: "ua.com.rmarinsky.diduny.mixer")

    // MARK: - Public Configuration

    /// Enable microphone capture alongside system audio.
    var captureMicrophone: Bool = false

    /// The microphone device to use. `nil` = system default.
    var microphoneDevice: AudioDevice?

    /// Gain applied to microphone samples before mixing (0–2, default 1.0).
    var micGain: Float = 1.0

    /// Gain applied to system audio samples before mixing (0–2, default 0.3).
    var systemGain: Float = 0.3

    var onError: ((Error) -> Void)?
    var onCaptureStarted: (() -> Void)?

    /// Raw mono s16le PCM data callback for cloud real-time transcription.
    var onRawAudioData: ((Data) -> Void)?

    /// Fired when microphone has been silent for > `silenceTimeout`.
    var onMicrophoneSilent: (() -> Void)?

    /// Fired when system audio has been silent for > `silenceTimeout`.
    var onSystemAudioSilent: (() -> Void)?

    // MARK: - Inline Mixer State (accessed only on mixerQueue)

    private var systemBuffer: [Float] = []
    private var micBuffer: [Float] = []
    /// Maximum single-source frames before flushing without counterpart (50ms at 16kHz).
    /// Kept low to minimize latency for real-time cloud transcription.
    private let flushThresholdFrames = 800

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

        Log.audio.info("Starting system audio capture (captureMicrophone=\(self.captureMicrophone))...")

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

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

        NSLog("[AudioCapture] Creating SCStream (system audio only)")

        stream = SCStream(filter: filter, configuration: config, delegate: self)

        guard let stream else {
            throw SystemAudioError.streamCreationFailed
        }

        // The .screen handler is needed on some macOS versions to unblock audio delivery.
        let outputQueue = DispatchQueue(label: "ua.com.rmarinsky.diduny.scstream.output")
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)

        try setupAudioFile(at: outputURL)

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

        try await stream.startCapture()
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
                try await cleanupFailedStart(removeOutputFile: true)
                throw SystemAudioError.microphoneStartFailed(error.localizedDescription)
            }
        }

        Log.audio.info("Capture started (16kHz mono, captureMicrophone=\(self.captureMicrophone))")
        NSLog("[AudioCapture] Capture started — waiting for delegate callbacks...")
        onCaptureStarted?()
    }

    // MARK: - Microphone Capture (AVAudioEngine)

    private func startMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        let shouldBindExplicitDevice = shouldBindExplicitDevice(microphoneDevice)

        // Set specific device if provided
        if shouldBindExplicitDevice, let device = microphoneDevice {
            let inputNode = engine.inputNode
            if let audioUnit = inputNode.audioUnit {
                var deviceID = device.id
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                Log.audio
                    .info(
                        "Meeting mic explicit binding to \(device.name), uid=\(device.uid), transport=\(device.transportType.displayName)"
                    )
                NSLog("[AudioCapture] Set mic engine device to %@ (id=%d)", device.name, device.id)
            }
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let nodeOutputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw SystemAudioError.microphoneFormatInvalid
        }

        Log.audio.info(
            "Meeting mic format resolved: input=\(self.formatDescription(inputFormat)), output=\(self.formatDescription(nodeOutputFormat)), explicitBinding=\(shouldBindExplicitDevice)"
        )
        NSLog(
            "[AudioCapture] Mic input format: sampleRate=%.0f, channels=%d",
            inputFormat.sampleRate,
            inputFormat.channelCount
        )

        // Create converter: native mic format → 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw SystemAudioError.microphoneFormatInvalid
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw SystemAudioError.microphoneFormatInvalid
        }

        micConverter = converter

        // Install tap — runs on audio render thread
        do {
            try ObjCExceptionCatcher.catchException {
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                    self?.processMicBuffer(buffer)
                }
            }
        } catch {
            Log.audio.error(
                "Meeting mic tap install failed. tapFormat=\(self.formatDescription(inputFormat)), nodeOutputFormat=\(self.formatDescription(nodeOutputFormat)), error=\(error.localizedDescription)"
            )
            throw SystemAudioError.microphoneStartFailed(
                "Could not start meeting microphone with the current route. Try reconnecting AirPods or choosing System Default."
            )
        }

        try engine.start()
        micEngine = engine

        NSLog("[AudioCapture] AVAudioEngine started for microphone capture")
    }

    private func stopMicrophoneCapture() {
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

    /// Convert mic buffer to 16kHz mono Float32 and dispatch to mixer queue.
    private func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
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

    func stopCapture() async throws -> URL? {
        guard isCapturing, let stream else {
            Log.audio.warning("Not capturing")
            return nil
        }

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

        try await stream.stopCapture()
        self.stream = nil
        isCapturing = false

        // Wait for pending mixer queue work, then flush remaining buffers
        mixerQueue.sync { [self] in
            fileWriteQueue.sync { [self] in
                flushRemainingBuffers()
            }
        }

        audioFile = nil
        outputFormat = nil
        sampleCount = 0
        systemBuffer.removeAll()
        micBuffer.removeAll()
        microphoneCaptureStarted = false

        Log.audio.info("Capture stopped, file saved to: \(self.outputURL?.path ?? "nil")")
        return outputURL
    }

    private func cleanupFailedStart(removeOutputFile: Bool) async throws {
        stopMicrophoneCapture()

        if let stream {
            try? await stream.stopCapture()
        }

        stream = nil
        isCapturing = false
        audioFile = nil
        outputFormat = nil
        sampleCount = 0
        systemBuffer.removeAll()
        micBuffer.removeAll()
        microphoneCaptureStarted = false

        if removeOutputFile, let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
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
    private func flushRemainingBuffers() {
        guard audioFile != nil else { return }

        if captureMicrophone {
            // Mix overlapping frames synchronously
            let mixCount = min(systemBuffer.count, micBuffer.count)
            if mixCount > 0 {
                var mixed = [Float](repeating: 0, count: mixCount)
                for i in 0 ..< mixCount {
                    mixed[i] = max(-1.0, min(1.0, systemBuffer[i] + micBuffer[i]))
                }
                systemBuffer.removeFirst(mixCount)
                micBuffer.removeFirst(mixCount)
                emitRealtimeData(mixed)
                writeSamples(mixed)
            }
            // Flush remaining single-source samples
            if !systemBuffer.isEmpty {
                emitRealtimeData(systemBuffer)
                writeSamples(systemBuffer)
                systemBuffer.removeAll()
            }
            if !micBuffer.isEmpty {
                emitRealtimeData(micBuffer)
                writeSamples(micBuffer)
                micBuffer.removeAll()
            }
        } else if !systemBuffer.isEmpty {
            emitRealtimeData(systemBuffer)
            writeSamples(systemBuffer)
            systemBuffer.removeAll()
        }
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCaptureService: SCStreamDelegate {
    func stream(_: SCStream, didStopWithError error: Error) {
        Log.audio.error("Stream stopped with error: \(error)")
        stopMicrophoneCapture()
        stream = nil
        isCapturing = false
        audioFile = nil
        outputFormat = nil
        systemBuffer.removeAll()
        micBuffer.removeAll()
        microphoneCaptureStarted = false
        onError?(error)
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCaptureService: SCStreamOutput {
    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
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
            let gained = samples.map { max(-1, min(1, $0 * systemGain)) }
            systemBuffer.append(contentsOf: gained)
            drainMixedSamples()
            flushStaleBuffer()
        } else {
            let gained = samples.map { max(-1, min(1, $0 * systemGain)) }
            emitRealtimeData(gained)
            fileWriteQueue.async { [weak self] in
                self?.writeSamples(gained)
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
        flushIfStale(&systemBuffer)
        flushIfStale(&micBuffer)
    }

    private func flushIfStale(_ buffer: inout [Float]) {
        guard buffer.count > flushThresholdFrames else { return }
        let stale = Array(buffer)
        buffer.removeAll()
        emitRealtimeData(stale)
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
    private func writeSamples(_ samples: [Float]) {
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

            let now = Date()
            if now.timeIntervalSince(lastFlushTime) >= flushInterval {
                Log.audio.info("Audio buffer auto-flush (every \(self.flushInterval)s)")
                lastFlushTime = now
            }
        } catch {
            Log.audio.error("Error writing audio: \(error)")
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

        if sampleCount <= 3 {
            Log.audio
                .info(
                    "Audio sample \(self.sampleCount): frames=\(frameCount), sampleRate=\(asbd.pointee.mSampleRate), ch=\(channelCount), bits=\(bitsPerChannel), float=\(isFloat)"
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
        for s in samples {
            sum += s * s
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
    case permissionDenied
    case microphoneFormatInvalid
    case microphoneStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            "No display found for screen capture"
        case .streamCreationFailed:
            "Failed to create audio capture stream"
        case .permissionDenied:
            "Screen recording permission required"
        case .microphoneFormatInvalid:
            "Invalid microphone audio format"
        case let .microphoneStartFailed(reason):
            reason
        }
    }
}
