import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import os

/// Service that mixes microphone and system audio in real-time and writes a single fallback WAV file.
/// It also exposes the same mixed PCM stream for cloud real-time transcription.
@available(macOS 13.0, *)
final class AudioMixerService {
    private enum Source {
        case microphone
        case system
    }

    // MARK: - Properties

    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var isRecording = false
    private var startTime: Date?

    // Audio engine for microphone capture
    private var audioEngine: AVAudioEngine?

    // Output format - 16kHz mono float for stable mixing and speech recognition.
    private let outputSampleRate: Double = 16000
    private let outputChannels: AVAudioChannelCount = 1

    // Silence detection
    private var lastMicAudioTime: Date?
    private var lastSystemAudioTime: Date?
    private let silenceThreshold: TimeInterval = 5.0

    // Thread-safe writing and mixing
    private let writeQueue = DispatchQueue(label: "ua.com.rmarinsky.diduny.audiomixer.write")
    private var hasWrittenData = false

    // Cached converters (keyed by input format hash) - must be used only on writeQueue
    private var converterCache: [String: AVAudioConverter] = [:]

    // Per-source sample queues (float32 mono, 16kHz timeline)
    private var micSamples: [Float] = []
    private var micReadIndex = 0
    private var systemSamples: [Float] = []
    private var systemReadIndex = 0
    private var lastMicBufferTime: Date?
    private var lastSystemBufferTime: Date?

    // If one source stalls for this long, continue writing with the active source only.
    private let sourceStallThreshold: TimeInterval = 0.35
    private let maxFramesPerWrite = 4096
    private let mixNormalization: Float = 0.7

    // Callbacks
    var onError: ((Error) -> Void)?
    var onMicrophoneSilent: (() -> Void)?
    var onSystemAudioSilent: (() -> Void)?

    /// Mixed mono audio chunks in s16le @ 16kHz for real-time cloud STT.
    var onMixedAudioData: ((Data) -> Void)?

    // MARK: - Start Recording

    func startRecording(to url: URL, includeMicrophone: Bool, microphoneDevice: AudioDevice? = nil) async throws {
        guard !isRecording else {
            Log.audio.warning("AudioMixer: Already recording")
            return
        }

        outputURL = url
        Log.audio.info("AudioMixer: Starting recording to \(url.path), includeMicrophone=\(includeMicrophone), device=\(microphoneDevice?.name ?? "default")")

        // Remove existing file
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: outputChannels,
            interleaved: false
        ) else {
            throw AudioMixerError.setupFailed("Failed to create output format")
        }

        // Create audio file for writing
        audioFile = try AVAudioFile(forWriting: url, settings: outputFormat.settings)
        Log.audio.info("AudioMixer: Audio file created at \(url.path)")

        // Reset mixing state
        micSamples.removeAll(keepingCapacity: true)
        systemSamples.removeAll(keepingCapacity: true)
        micReadIndex = 0
        systemReadIndex = 0
        let now = Date()
        lastMicBufferTime = now
        lastSystemBufferTime = now

        // Setup microphone if requested
        if includeMicrophone {
            try setupMicrophoneCapture(outputFormat: outputFormat, device: microphoneDevice)
        }

        isRecording = true
        startTime = Date()
        hasWrittenData = false

        Log.audio.info("AudioMixer: Recording started")
    }

    // MARK: - Microphone Setup

    private func setupMicrophoneCapture(outputFormat: AVAudioFormat, device: AudioDevice?) throws {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode

        // Set specific input device if provided
        if let device {
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
                    Log.audio.info("AudioMixer: Set microphone device to '\(device.name)' (ID: \(device.id))")
                } else {
                    Log.audio.warning("AudioMixer: Failed to set microphone device, status=\(status)")
                }
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        Log.audio.info("AudioMixer: Mic input format - sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")

        guard inputFormat.sampleRate > 0, outputFormat.sampleRate > 0 else {
            throw AudioMixerError.setupFailed("Invalid sample rate")
        }

        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.isRecording else { return }

            if self.hasAudioContent(buffer) {
                self.lastMicAudioTime = Date()
            }

            // Copy buffer and queue for mixing/writing (buffer may be reused by AVAudioEngine)
            self.queueBufferForWriting(buffer: buffer, inputFormat: inputFormat, source: .microphone)
        }

        try engine.start()
        Log.audio.info("AudioMixer: Microphone capture started")
    }

    // MARK: - System Audio Input

    private var systemAudioBufferCount = 0

    /// Feed system audio buffer from ScreenCaptureKit.
    func feedSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording, audioFile != nil else { return }

        systemAudioBufferCount += 1

        if systemAudioBufferCount <= 3,
           let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        {
            Log.audio.info("AudioMixer: System audio buffer #\(self.systemAudioBufferCount) - sampleRate=\(asbd.pointee.mSampleRate), channels=\(asbd.pointee.mChannelsPerFrame), samples=\(CMSampleBufferGetNumSamples(sampleBuffer))")
        }

        guard let pcmBuffer = convertCMSampleBufferToPCM(sampleBuffer) else {
            if systemAudioBufferCount <= 3 {
                Log.audio.error("AudioMixer: Failed to convert system audio buffer #\(self.systemAudioBufferCount)")
            }
            return
        }

        if hasAudioContent(pcmBuffer) {
            lastSystemAudioTime = Date()
        }

        queueBufferForWriting(buffer: pcmBuffer, inputFormat: pcmBuffer.format, source: .system)
    }

    // MARK: - Buffer Conversion and Mixing

    /// Copies buffer data synchronously, then processes conversion/mixing on writeQueue.
    private func queueBufferForWriting(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, source: Source) {
        guard inputFormat.sampleRate > 0 else {
            Log.audio.warning("AudioMixer: Invalid input format - sampleRate=\(inputFormat.sampleRate)")
            return
        }

        let frameCount = buffer.frameLength
        guard frameCount > 0 else { return }

        guard let safeCopiedBuffer = copyAudioBuffer(buffer, inputFormat: inputFormat, frameCount: frameCount) else {
            Log.audio.warning("AudioMixer: Failed to copy buffer from \(source == .microphone ? "mic" : "system")")
            return
        }

        let formatKey = "\(inputFormat.sampleRate)-\(inputFormat.channelCount)-\(inputFormat.commonFormat.rawValue)-\(inputFormat.isInterleaved)"

        writeQueue.async { [weak self] in
            guard let self, let audioFile = self.audioFile, self.isRecording else { return }

            let fileProcessingFormat = audioFile.processingFormat

            let converter: AVAudioConverter
            if let cached = self.converterCache[formatKey] {
                converter = cached
            } else {
                guard let newConverter = AVAudioConverter(from: inputFormat, to: fileProcessingFormat) else {
                    Log.audio.error("AudioMixer: Failed to create converter - input: \(inputFormat), output: \(fileProcessingFormat)")
                    return
                }
                self.converterCache[formatKey] = newConverter
                converter = newConverter
                Log.audio.info("AudioMixer: Created converter for \(source == .microphone ? "mic" : "system") - input: sampleRate=\(inputFormat.sampleRate), ch=\(inputFormat.channelCount), format=\(inputFormat.commonFormat.rawValue), interleaved=\(inputFormat.isInterleaved) -> output: sampleRate=\(fileProcessingFormat.sampleRate), ch=\(fileProcessingFormat.channelCount), format=\(fileProcessingFormat.commonFormat.rawValue), interleaved=\(fileProcessingFormat.isInterleaved)")
            }

            let ratio = fileProcessingFormat.sampleRate / inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
            guard outputFrameCount > 0 else { return }

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: fileProcessingFormat, frameCapacity: outputFrameCount) else {
                Log.audio.error("AudioMixer: Failed to create output buffer - format: \(fileProcessingFormat), capacity: \(outputFrameCount)")
                return
            }

            var error: NSError?
            var hasInputData = true

            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if hasInputData {
                    hasInputData = false
                    outStatus.pointee = .haveData
                    return safeCopiedBuffer
                }
                outStatus.pointee = .noDataNow
                return nil
            }

            if let error {
                if !self.hasWrittenData {
                    Log.audio.error("AudioMixer: Conversion error from \(source == .microphone ? "mic" : "system") - \(error.localizedDescription)")
                }
                return
            }

            guard status != .error else {
                Log.audio.warning("AudioMixer: Converter returned error status from \(source == .microphone ? "mic" : "system")")
                return
            }

            guard outputBuffer.frameLength > 0 else {
                return
            }

            self.enqueueConvertedSamples(outputBuffer, source: source, fileProcessingFormat: fileProcessingFormat)
        }
    }

    private func copyAudioBuffer(
        _ buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
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

    private func enqueueConvertedSamples(
        _ buffer: AVAudioPCMBuffer,
        source: Source,
        fileProcessingFormat: AVAudioFormat
    ) {
        guard let monoSamples = extractMonoFloatSamples(from: buffer), !monoSamples.isEmpty else {
            Log.audio.warning("AudioMixer: Failed to extract converted samples from \(source == .microphone ? "mic" : "system")")
            return
        }

        let now = Date()
        switch source {
        case .microphone:
            micSamples.append(contentsOf: monoSamples)
            lastMicBufferTime = now
        case .system:
            systemSamples.append(contentsOf: monoSamples)
            lastSystemBufferTime = now
        }

        mixAndWriteAvailableFrames(fileProcessingFormat: fileProcessingFormat, flush: false)
    }

    private func extractMonoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let channelCount = Int(buffer.format.channelCount)

        if let floatChannelData = buffer.floatChannelData {
            if channelCount == 1 {
                return Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameCount))
            }

            var mixed = Array(repeating: Float(0), count: frameCount)
            let normalization = 1.0 / Float(max(channelCount, 1))
            for channel in 0 ..< channelCount {
                let channelSamples = UnsafeBufferPointer(start: floatChannelData[channel], count: frameCount)
                for index in 0 ..< frameCount {
                    mixed[index] += channelSamples[index]
                }
            }
            for index in 0 ..< frameCount {
                mixed[index] *= normalization
            }
            return mixed
        }

        if let int16ChannelData = buffer.int16ChannelData {
            if channelCount == 1 {
                return (0 ..< frameCount).map { Float(int16ChannelData[0][$0]) / Float(Int16.max) }
            }

            var mixed = Array(repeating: Float(0), count: frameCount)
            let normalization = 1.0 / Float(max(channelCount, 1))
            for channel in 0 ..< channelCount {
                let channelSamples = int16ChannelData[channel]
                for index in 0 ..< frameCount {
                    mixed[index] += Float(channelSamples[index]) / Float(Int16.max)
                }
            }
            for index in 0 ..< frameCount {
                mixed[index] *= normalization
            }
            return mixed
        }

        return nil
    }

    private func mixAndWriteAvailableFrames(fileProcessingFormat: AVAudioFormat, flush: Bool) {
        guard let audioFile else { return }

        while true {
            let micAvailable = micSamples.count - micReadIndex
            let systemAvailable = systemSamples.count - systemReadIndex

            if micAvailable <= 0, systemAvailable <= 0 {
                break
            }

            var micFramesToConsume = 0
            var systemFramesToConsume = 0

            let syncedFrames = min(micAvailable, systemAvailable)
            if syncedFrames > 0 {
                let frameCount = min(syncedFrames, maxFramesPerWrite)
                micFramesToConsume = frameCount
                systemFramesToConsume = frameCount
            } else if flush {
                micFramesToConsume = min(micAvailable, maxFramesPerWrite)
                systemFramesToConsume = min(systemAvailable, maxFramesPerWrite)
            } else {
                let now = Date()
                if micAvailable > 0,
                   shouldFallbackToSingleSource(now: now, missingSource: .system)
                {
                    micFramesToConsume = min(micAvailable, maxFramesPerWrite)
                } else if systemAvailable > 0,
                          shouldFallbackToSingleSource(now: now, missingSource: .microphone)
                {
                    systemFramesToConsume = min(systemAvailable, maxFramesPerWrite)
                } else {
                    break
                }
            }

            let framesToWrite = max(micFramesToConsume, systemFramesToConsume)
            guard framesToWrite > 0 else { break }

            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: fileProcessingFormat,
                frameCapacity: AVAudioFrameCount(framesToWrite)
            ) else {
                Log.audio.error("AudioMixer: Failed to create mixed output buffer")
                break
            }
            outputBuffer.frameLength = AVAudioFrameCount(framesToWrite)

            // Write float32 mono to fallback file
            if let out = outputBuffer.floatChannelData?[0] {
                for index in 0 ..< framesToWrite {
                    let micSample: Float = index < micFramesToConsume ? micSamples[micReadIndex + index] : 0
                    let systemSample: Float = index < systemFramesToConsume ? systemSamples[systemReadIndex + index] : 0
                    out[index] = clamp((micSample + systemSample) * mixNormalization)
                }
            } else if let out = outputBuffer.int16ChannelData?[0] {
                for index in 0 ..< framesToWrite {
                    let micSample: Float = index < micFramesToConsume ? micSamples[micReadIndex + index] : 0
                    let systemSample: Float = index < systemFramesToConsume ? systemSamples[systemReadIndex + index] : 0
                    let mixed = clamp((micSample + systemSample) * mixNormalization)
                    out[index] = Int16(mixed * Float(Int16.max))
                }
            } else {
                Log.audio.error("AudioMixer: Unsupported output buffer format")
                break
            }

            do {
                try audioFile.write(from: outputBuffer)
                if !hasWrittenData {
                    hasWrittenData = true
                    Log.audio.info("AudioMixer: Started writing mixed audio data")
                }
            } catch {
                Log.audio.error("AudioMixer: Write error - \(error.localizedDescription)")
                onError?(error)
                break
            }

            if let onMixedAudioData {
                let pcmData = toInt16PCMData(buffer: outputBuffer)
                if !pcmData.isEmpty {
                    onMixedAudioData(pcmData)
                }
            }

            micReadIndex += micFramesToConsume
            systemReadIndex += systemFramesToConsume
            compactQueuesIfNeeded()
        }
    }

    private func shouldFallbackToSingleSource(now: Date, missingSource: Source) -> Bool {
        switch missingSource {
        case .microphone:
            guard let lastMicBufferTime else { return false }
            return now.timeIntervalSince(lastMicBufferTime) > sourceStallThreshold
        case .system:
            guard let lastSystemBufferTime else { return false }
            return now.timeIntervalSince(lastSystemBufferTime) > sourceStallThreshold
        }
    }

    private func toInt16PCMData(buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return Data() }

        if let floatData = buffer.floatChannelData?[0] {
            var data = Data(count: frameCount * MemoryLayout<Int16>.size)
            data.withUnsafeMutableBytes { rawBuffer in
                let destination = rawBuffer.bindMemory(to: Int16.self)
                for index in 0 ..< frameCount {
                    let sample = clamp(floatData[index])
                    destination[index] = Int16(sample * Float(Int16.max))
                }
            }
            return data
        }

        if let int16Data = buffer.int16ChannelData?[0] {
            return Data(bytes: int16Data, count: frameCount * MemoryLayout<Int16>.size)
        }

        return Data()
    }

    private func compactQueuesIfNeeded() {
        compactQueue(&micSamples, readIndex: &micReadIndex)
        compactQueue(&systemSamples, readIndex: &systemReadIndex)
    }

    private func compactQueue(_ queue: inout [Float], readIndex: inout Int) {
        guard readIndex > 0 else { return }

        if readIndex >= queue.count {
            queue.removeAll(keepingCapacity: true)
            readIndex = 0
            return
        }

        if readIndex >= 8192, readIndex * 2 >= queue.count {
            queue.removeFirst(readIndex)
            readIndex = 0
        }
    }

    private func clamp(_ value: Float) -> Float {
        max(-1.0, min(1.0, value))
    }

    // MARK: - CMSampleBuffer to PCM Conversion

    private func convertCMSampleBufferToPCM(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        guard let inputFormat = AVAudioFormat(streamDescription: asbd) else {
            return nil
        }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(numSamples)
        ) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }

        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0

        if isFloat, let floatData = pcmBuffer.floatChannelData {
            if isNonInterleaved {
                let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
                for channel in 0 ..< min(channelCount, Int(inputFormat.channelCount)) {
                    let channelOffset = channel * numSamples * bytesPerFrame
                    memcpy(floatData[channel], data.advanced(by: channelOffset), numSamples * bytesPerFrame)
                }
            } else {
                let srcPtr = UnsafeRawPointer(data)
                for frame in 0 ..< numSamples {
                    for channel in 0 ..< min(channelCount, Int(inputFormat.channelCount)) {
                        let srcOffset = (frame * channelCount + channel) * MemoryLayout<Float>.size
                        floatData[channel][frame] = srcPtr.load(fromByteOffset: srcOffset, as: Float.self)
                    }
                }
            }
        } else if let int16Data = pcmBuffer.int16ChannelData {
            if isNonInterleaved {
                let bytesPerSample = MemoryLayout<Int16>.size
                for channel in 0 ..< min(channelCount, Int(inputFormat.channelCount)) {
                    let channelOffset = channel * numSamples * bytesPerSample
                    memcpy(int16Data[channel], data.advanced(by: channelOffset), numSamples * bytesPerSample)
                }
            } else {
                memcpy(int16Data[0], data, totalLength)
            }
        }

        return pcmBuffer
    }

    // MARK: - Silence Detection

    private func hasAudioContent(_ buffer: AVAudioPCMBuffer) -> Bool {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return false }

        if let floatData = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for index in 0 ..< frameCount {
                let sample = floatData[index]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameCount))
            return rms > 0.001
        }

        if let int16Data = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for index in 0 ..< frameCount {
                let sample = Float(int16Data[index]) / 32768.0
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameCount))
            return rms > 0.001
        }

        return false
    }

    var isMicrophoneSilent: Bool {
        guard let lastTime = lastMicAudioTime else { return true }
        return Date().timeIntervalSince(lastTime) > silenceThreshold
    }

    var isSystemAudioSilent: Bool {
        guard let lastTime = lastSystemAudioTime else { return true }
        return Date().timeIntervalSince(lastTime) > silenceThreshold
    }

    // MARK: - Stop Recording

    func stopRecording() async throws -> URL? {
        guard isRecording else {
            Log.audio.warning("AudioMixer: Not recording")
            return nil
        }

        Log.audio.info("AudioMixer: Stopping recording...")

        isRecording = false

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        // Wait for pending conversions/writes and flush remainder.
        writeQueue.sync {
            if let format = audioFile?.processingFormat {
                mixAndWriteAvailableFrames(fileProcessingFormat: format, flush: true)
            }
        }

        let finalURL = outputURL
        audioFile = nil

        if let start = startTime {
            let duration = Date().timeIntervalSince(start)
            Log.audio.info("AudioMixer: Recording stopped, duration=\(String(format: "%.2f", duration))s, hasData=\(self.hasWrittenData)")
        }

        outputURL = nil
        startTime = nil
        lastMicAudioTime = nil
        lastSystemAudioTime = nil
        lastMicBufferTime = nil
        lastSystemBufferTime = nil
        systemAudioBufferCount = 0
        converterCache.removeAll()
        micSamples.removeAll(keepingCapacity: true)
        systemSamples.removeAll(keepingCapacity: true)
        micReadIndex = 0
        systemReadIndex = 0

        return finalURL
    }

    // MARK: - Recording Duration

    var recordingDuration: TimeInterval {
        guard let start = startTime else { return 0 }
        return Date().timeIntervalSince(start)
    }
}

// MARK: - Errors

enum AudioMixerError: LocalizedError {
    case setupFailed(String)
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .setupFailed(reason):
            "Audio mixer setup failed: \(reason)"
        case let .recordingFailed(reason):
            "Audio recording failed: \(reason)"
        }
    }
}
