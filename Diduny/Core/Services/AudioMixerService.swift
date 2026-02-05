import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import os

/// Service that mixes microphone and system audio in real-time, outputting to AAC format.
/// Handles fallback scenarios where one audio source may be silent or unavailable.
@available(macOS 13.0, *)
final class AudioMixerService {
    // MARK: - Properties

    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var isRecording = false
    private var startTime: Date?

    // Audio engine for microphone capture
    private var audioEngine: AVAudioEngine?

    // Output format - 16kHz is optimal for Soniox speech recognition
    private let outputSampleRate: Double = 16000
    private let outputChannels: AVAudioChannelCount = 1

    // Silence detection
    private var lastMicAudioTime: Date?
    private var lastSystemAudioTime: Date?
    private let silenceThreshold: TimeInterval = 5.0

    // Thread-safe writing
    private let writeQueue = DispatchQueue(label: "ua.com.rmarinsky.diduny.audiomixer.write")
    private var hasWrittenData = false

    // Cached converters (keyed by input format hash) - must be used only on writeQueue
    private var converterCache: [String: AVAudioConverter] = [:]

    // Callbacks
    var onError: ((Error) -> Void)?
    var onMicrophoneSilent: (() -> Void)?
    var onSystemAudioSilent: (() -> Void)?

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

        // Create output format - 48kHz mono 32-bit Float PCM (WAV)
        // Using Float32 for processing (AVAudioEngine native format)
        // AVAudioFile will handle conversion to file format internally
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

        // Validate formats are compatible
        guard inputFormat.sampleRate > 0, outputFormat.sampleRate > 0 else {
            throw AudioMixerError.setupFailed("Invalid sample rate")
        }

        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.isRecording else { return }

            // Check for audio content (silence detection)
            if self.hasAudioContent(buffer) {
                self.lastMicAudioTime = Date()
            }

            // Copy buffer and queue for writing (buffer may be reused by AVAudioEngine)
            self.queueBufferForWriting(buffer: buffer, inputFormat: inputFormat, source: "mic")
        }

        // Start engine
        try engine.start()
        Log.audio.info("AudioMixer: Microphone capture started")
    }

    // MARK: - System Audio Input

    // Track system audio buffer count for logging
    private var systemAudioBufferCount = 0

    /// Feed system audio buffer from ScreenCaptureKit
    func feedSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording, audioFile != nil else { return }

        systemAudioBufferCount += 1

        // Log first few buffers for debugging
        if systemAudioBufferCount <= 3 {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
            {
                Log.audio.info("AudioMixer: System audio buffer #\(self.systemAudioBufferCount) - sampleRate=\(asbd.pointee.mSampleRate), channels=\(asbd.pointee.mChannelsPerFrame), samples=\(CMSampleBufferGetNumSamples(sampleBuffer))")
            }
        }

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let pcmBuffer = convertCMSampleBufferToPCM(sampleBuffer) else {
            if systemAudioBufferCount <= 3 {
                Log.audio.error("AudioMixer: Failed to convert system audio buffer #\(self.systemAudioBufferCount)")
            }
            return
        }

        // Check for audio content
        if hasAudioContent(pcmBuffer) {
            lastSystemAudioTime = Date()
        }

        // Queue for writing (converter will be created on writeQueue)
        queueBufferForWriting(buffer: pcmBuffer, inputFormat: pcmBuffer.format, source: "system")
    }

    // MARK: - Buffer Conversion and Writing

    /// Copies buffer data synchronously, then processes on writeQueue
    private func queueBufferForWriting(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, source: String) {
        // Validate input format before copying
        guard inputFormat.sampleRate > 0 else {
            Log.audio.warning("AudioMixer: Invalid input format - sampleRate=\(inputFormat.sampleRate)")
            return
        }

        let frameCount = buffer.frameLength
        guard frameCount > 0 else { return }

        // Copy the raw audio data synchronously (before async dispatch)
        // This prevents use-after-free when the original buffer is reused
        let copiedBuffer: AVAudioPCMBuffer?

        if let floatData = buffer.floatChannelData {
            // Float format - copy float data
            copiedBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount)
            copiedBuffer?.frameLength = frameCount

            if let destFloatData = copiedBuffer?.floatChannelData {
                let channelCount = Int(inputFormat.channelCount)
                for ch in 0 ..< channelCount {
                    memcpy(destFloatData[ch], floatData[ch], Int(frameCount) * MemoryLayout<Float>.size)
                }
            }
        } else if let int16Data = buffer.int16ChannelData {
            // Int16 format - copy int16 data
            copiedBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount)
            copiedBuffer?.frameLength = frameCount

            if let destInt16Data = copiedBuffer?.int16ChannelData {
                let channelCount = Int(inputFormat.channelCount)
                let isInterleaved = inputFormat.isInterleaved

                if isInterleaved {
                    // Interleaved: all data in channel 0
                    let bytesToCopy = Int(frameCount) * channelCount * MemoryLayout<Int16>.size
                    memcpy(destInt16Data[0], int16Data[0], bytesToCopy)
                } else {
                    // Non-interleaved: separate channel buffers
                    for ch in 0 ..< channelCount {
                        memcpy(destInt16Data[ch], int16Data[ch], Int(frameCount) * MemoryLayout<Int16>.size)
                    }
                }
            }
        } else {
            Log.audio.warning("AudioMixer: Unknown buffer format from \(source)")
            return
        }

        guard let safeCopiedBuffer = copiedBuffer else {
            Log.audio.warning("AudioMixer: Failed to copy buffer from \(source)")
            return
        }

        // Create format key for converter cache
        let formatKey = "\(inputFormat.sampleRate)-\(inputFormat.channelCount)-\(inputFormat.commonFormat.rawValue)"

        // Now dispatch to writeQueue with the copied buffer
        writeQueue.async { [weak self] in
            guard let self, let audioFile = self.audioFile, self.isRecording else { return }

            // Get file's processing format (what it expects for writes)
            let fileProcessingFormat = audioFile.processingFormat

            // Get or create converter (on writeQueue for thread safety)
            let converter: AVAudioConverter
            if let cached = self.converterCache[formatKey] {
                converter = cached
            } else {
                // Create converter from input format to file's processing format
                guard let newConverter = AVAudioConverter(from: inputFormat, to: fileProcessingFormat) else {
                    Log.audio.error("AudioMixer: Failed to create converter - input: \(inputFormat), output: \(fileProcessingFormat)")
                    return
                }
                self.converterCache[formatKey] = newConverter
                converter = newConverter
                Log.audio.info("AudioMixer: Created converter for \(source) - input: sampleRate=\(inputFormat.sampleRate), ch=\(inputFormat.channelCount), format=\(inputFormat.commonFormat.rawValue), interleaved=\(inputFormat.isInterleaved) -> output: sampleRate=\(fileProcessingFormat.sampleRate), ch=\(fileProcessingFormat.channelCount), format=\(fileProcessingFormat.commonFormat.rawValue), interleaved=\(fileProcessingFormat.isInterleaved)")
            }

            // Calculate output frame count using file's processing format
            let ratio = fileProcessingFormat.sampleRate / inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)

            guard outputFrameCount > 0 else { return }

            // Create output buffer with file's processing format
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: fileProcessingFormat, frameCapacity: outputFrameCount) else {
                Log.audio.error("AudioMixer: Failed to create output buffer - format: \(fileProcessingFormat), capacity: \(outputFrameCount)")
                return
            }

            // Convert
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
                    Log.audio.error("AudioMixer: Conversion error from \(source) - \(error.localizedDescription)")
                }
                return
            }

            guard status != .error else {
                Log.audio.warning("AudioMixer: Converter returned error status from \(source)")
                return
            }

            guard outputBuffer.frameLength > 0 else {
                Log.audio.warning("AudioMixer: Output buffer has 0 frames from \(source)")
                return
            }

            // Verify buffer format matches file format before writing
            guard outputBuffer.format.sampleRate == fileProcessingFormat.sampleRate,
                  outputBuffer.format.channelCount == fileProcessingFormat.channelCount,
                  outputBuffer.format.commonFormat == fileProcessingFormat.commonFormat else {
                Log.audio.error("AudioMixer: Format mismatch - buffer: sampleRate=\(outputBuffer.format.sampleRate), ch=\(outputBuffer.format.channelCount), fmt=\(outputBuffer.format.commonFormat.rawValue) vs file: sampleRate=\(fileProcessingFormat.sampleRate), ch=\(fileProcessingFormat.channelCount), fmt=\(fileProcessingFormat.commonFormat.rawValue)")
                return
            }

            // Write to file with defensive error handling
            do {
                try audioFile.write(from: outputBuffer)
                if !self.hasWrittenData {
                    self.hasWrittenData = true
                    Log.audio.info("AudioMixer: Started writing audio data from \(source) - format: \(outputBuffer.format)")
                }
            } catch {
                Log.audio.error("AudioMixer: Write error from \(source) - \(error.localizedDescription)")
            }
        }
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

        // Get data from sample buffer
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

        // Copy audio data to PCM buffer
        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0

        if isFloat, let floatData = pcmBuffer.floatChannelData {
            if isNonInterleaved {
                // Non-interleaved float
                let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
                for channel in 0 ..< min(channelCount, Int(inputFormat.channelCount)) {
                    let channelOffset = channel * numSamples * bytesPerFrame
                    memcpy(floatData[channel], data.advanced(by: channelOffset), numSamples * bytesPerFrame)
                }
            } else {
                // Interleaved float - deinterleave
                let srcPtr = UnsafeRawPointer(data)
                for frame in 0 ..< numSamples {
                    for channel in 0 ..< min(channelCount, Int(inputFormat.channelCount)) {
                        let srcOffset = (frame * channelCount + channel) * MemoryLayout<Float>.size
                        floatData[channel][frame] = srcPtr.load(fromByteOffset: srcOffset, as: Float.self)
                    }
                }
            }
        } else if let int16Data = pcmBuffer.int16ChannelData {
            // 16-bit integer
            if isNonInterleaved {
                let bytesPerSample = MemoryLayout<Int16>.size
                for channel in 0 ..< min(channelCount, Int(inputFormat.channelCount)) {
                    let channelOffset = channel * numSamples * bytesPerSample
                    memcpy(int16Data[channel], data.advanced(by: channelOffset), numSamples * bytesPerSample)
                }
            } else {
                // Interleaved
                memcpy(int16Data[0], data, totalLength)
            }
        }

        return pcmBuffer
    }

    // MARK: - Silence Detection

    private func hasAudioContent(_ buffer: AVAudioPCMBuffer) -> Bool {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return false }

        // Check float data
        if let floatData = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0 ..< frameCount {
                let sample = floatData[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameCount))
            return rms > 0.001
        }

        // Check int16 data
        if let int16Data = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for i in 0 ..< frameCount {
                let sample = Float(int16Data[i]) / 32768.0
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

        // Stop audio engine
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        // Wait for pending writes to complete
        writeQueue.sync {}

        // Close audio file
        let finalURL = outputURL
        audioFile = nil

        // Log stats
        if let start = startTime {
            let duration = Date().timeIntervalSince(start)
            Log.audio.info("AudioMixer: Recording stopped, duration=\(String(format: "%.2f", duration))s, hasData=\(self.hasWrittenData)")
        }

        // Cleanup
        outputURL = nil
        startTime = nil
        lastMicAudioTime = nil
        lastSystemAudioTime = nil
        systemAudioBufferCount = 0
        converterCache.removeAll()

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
