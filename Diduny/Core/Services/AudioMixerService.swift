import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import os

/// Service that mixes microphone and system audio in real-time and writes a single fallback WAV file.
/// It also exposes the same mixed PCM stream for cloud real-time transcription.
@available(macOS 13.0, *)
final class AudioMixerService {
    private enum Source: String {
        case microphone
        case system
    }

    private struct AudioChunk {
        let startFrame: Int64
        let samples: [Float]

        var endFrame: Int64 {
            startFrame + Int64(samples.count)
        }
    }

    private struct SourceTimelineState {
        var firstTimestampSeconds: TimeInterval?
        var startFrameOffset: Int64 = 0
        var nextFrameEstimate: Int64 = 0

        mutating func reset() {
            firstTimestampSeconds = nil
            startFrameOffset = 0
            nextFrameEstimate = 0
        }
    }

    private struct MixerTelemetry: Equatable {
        var micUnderflowFrames: Int64 = 0
        var systemUnderflowFrames: Int64 = 0
        var micOverflowFrames: Int64 = 0
        var systemOverflowFrames: Int64 = 0
        var mixedFramesWritten: Int64 = 0
        var quantumCount: Int64 = 0
        var maxInterSourceFrameDelta: Int64 = 0
    }

    /// Timestamp-aware bounded queue for source frames in mixer timeline.
    private final class TimestampedRingBuffer {
        private let capacityFrames: Int
        private var chunks: [AudioChunk] = []
        private var totalFrames: Int = 0

        init(capacityFrames: Int) {
            self.capacityFrames = max(1, capacityFrames)
        }

        var earliestFrame: Int64? {
            chunks.first?.startFrame
        }

        var latestFrame: Int64? {
            chunks.last?.endFrame
        }

        func reset() {
            chunks.removeAll(keepingCapacity: true)
            totalFrames = 0
        }

        /// Appends a chunk in timeline coordinates.
        /// Returns number of dropped (oldest) frames due to ring overflow.
        @discardableResult
        func append(startFrame: Int64, samples: [Float]) -> Int {
            guard !samples.isEmpty else { return 0 }

            var normalizedStartFrame = max(0, startFrame)
            var normalizedSamples = samples

            // Ensure monotonic chunk sequence; trim overlaps to keep lookup simple.
            if let last = chunks.last, normalizedStartFrame < last.endFrame {
                let overlapFrames = Int(last.endFrame - normalizedStartFrame)
                if overlapFrames >= normalizedSamples.count {
                    return 0
                }

                normalizedStartFrame = last.endFrame
                normalizedSamples = Array(normalizedSamples.dropFirst(overlapFrames))
            }

            guard !normalizedSamples.isEmpty else { return 0 }

            let chunk = AudioChunk(startFrame: normalizedStartFrame, samples: normalizedSamples)
            chunks.append(chunk)
            totalFrames += chunk.samples.count

            var droppedFrames = 0
            while totalFrames > capacityFrames, !chunks.isEmpty {
                let overflowFrames = totalFrames - capacityFrames
                let firstChunk = chunks[0]

                if overflowFrames >= firstChunk.samples.count {
                    droppedFrames += firstChunk.samples.count
                    totalFrames -= firstChunk.samples.count
                    chunks.removeFirst()
                    continue
                }

                droppedFrames += overflowFrames
                totalFrames -= overflowFrames

                let trimmedSamples = Array(firstChunk.samples.dropFirst(overflowFrames))
                chunks[0] = AudioChunk(
                    startFrame: firstChunk.startFrame + Int64(overflowFrames),
                    samples: trimmedSamples
                )
            }

            return droppedFrames
        }

        /// Copies overlap with [rangeStart, rangeStart + destination.count) into destination.
        /// Returns number of frames that were provided by this source.
        func fill(rangeStart: Int64, destination: inout [Float]) -> Int {
            guard !destination.isEmpty, !chunks.isEmpty else { return 0 }

            let rangeEnd = rangeStart + Int64(destination.count)
            var filledFrames = 0

            for chunk in chunks {
                if chunk.endFrame <= rangeStart {
                    continue
                }
                if chunk.startFrame >= rangeEnd {
                    break
                }

                let overlapStart = max(rangeStart, chunk.startFrame)
                let overlapEnd = min(rangeEnd, chunk.endFrame)
                let overlapFrameCount = Int(overlapEnd - overlapStart)
                guard overlapFrameCount > 0 else { continue }

                let sourceOffset = Int(overlapStart - chunk.startFrame)
                let destinationOffset = Int(overlapStart - rangeStart)

                for index in 0 ..< overlapFrameCount {
                    destination[destinationOffset + index] = chunk.samples[sourceOffset + index]
                }

                filledFrames += overlapFrameCount
            }

            return filledFrames
        }

        func discard(upToFrame frame: Int64) {
            while let first = chunks.first, first.endFrame <= frame {
                totalFrames -= first.samples.count
                chunks.removeFirst()
            }

            guard !chunks.isEmpty else { return }
            let first = chunks[0]

            if frame > first.startFrame, frame < first.endFrame {
                let dropFrames = Int(frame - first.startFrame)
                guard dropFrames > 0 else { return }

                totalFrames -= dropFrames
                let trimmedSamples = Array(first.samples.dropFirst(dropFrames))
                chunks[0] = AudioChunk(startFrame: frame, samples: trimmedSamples)
            }
        }
    }

    // MARK: - Properties

    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var isRecording = false
    private var isStopping = false
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

    // Timestamped source ring buffers (all in output timeline/frame space)
    private let ringBufferCapacityFrames = 16000 * 20 // 20 seconds per source
    private var micRingBuffer = TimestampedRingBuffer(capacityFrames: 16000 * 20)
    private var systemRingBuffer = TimestampedRingBuffer(capacityFrames: 16000 * 20)
    private var micTimeline = SourceTimelineState()
    private var systemTimeline = SourceTimelineState()

    // Mixer clock / scheduling
    private var mixCursorFrame: Int64 = 0
    private var hasInitializedMixCursor = false
    private var includeMicrophoneInMix = true
    private let mixQuantumFrames = 160 // 10ms @ 16kHz
    private let mixLookaheadFrames = 320 // 20ms jitter buffer
    private let ringDiscardGuardFrames = 1600 // keep ~100ms history for overlap safety
    private let sourceStallThreshold: TimeInterval = 1.0
    private let mixNormalization: Float = 0.7

    // Arrival timestamps for stall detection
    private var lastMicChunkEnqueueTime: Date?
    private var lastSystemChunkEnqueueTime: Date?

    // Telemetry (underflow/overflow and sync quality)
    private var telemetry = MixerTelemetry()
    private var lastTelemetrySnapshot = MixerTelemetry()
    private var lastTelemetryLogTime = Date()
    private let telemetryLogInterval: TimeInterval = 5.0

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
        includeMicrophoneInMix = includeMicrophone
        micRingBuffer.reset()
        systemRingBuffer.reset()
        micTimeline.reset()
        systemTimeline.reset()
        mixCursorFrame = 0
        hasInitializedMixCursor = false

        converterCache.removeAll()
        telemetry = MixerTelemetry()
        lastTelemetrySnapshot = MixerTelemetry()
        lastTelemetryLogTime = Date()

        lastMicChunkEnqueueTime = nil
        lastSystemChunkEnqueueTime = nil

        let now = Date()
        lastMicAudioTime = now
        lastSystemAudioTime = now

        // Setup microphone if requested
        if includeMicrophone {
            try setupMicrophoneCapture(outputFormat: outputFormat, device: microphoneDevice)
        }

        isRecording = true
        startTime = Date()
        hasWrittenData = false

        Log.audio.info("AudioMixer: Recording started, ringCapacityFrames=\(self.ringBufferCapacityFrames)")
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
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, when in
            guard let self, self.isRecording, !self.isStopping else { return }

            if self.hasAudioContent(buffer) {
                self.lastMicAudioTime = Date()
            }

            let timestampSeconds = self.microphoneTimestampSeconds(from: when)

            // Copy buffer and queue for conversion + timestamped ring-buffer mixing.
            self.queueBufferForWriting(
                buffer: buffer,
                inputFormat: inputFormat,
                source: .microphone,
                sourceTimestampSeconds: timestampSeconds
            )
        }

        try engine.start()
        Log.audio.info("AudioMixer: Microphone capture started")
    }

    // MARK: - System Audio Input

    private var systemAudioBufferCount = 0

    /// Feed system audio buffer from ScreenCaptureKit.
    func feedSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording, !isStopping, audioFile != nil else { return }

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

        let timestampSeconds = systemTimestampSeconds(from: sampleBuffer)

        queueBufferForWriting(
            buffer: pcmBuffer,
            inputFormat: pcmBuffer.format,
            source: .system,
            sourceTimestampSeconds: timestampSeconds
        )
    }

    // MARK: - Buffer Conversion and Mixing

    /// Copies buffer data synchronously, then processes conversion/mixing on writeQueue.
    private func queueBufferForWriting(
        buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        source: Source,
        sourceTimestampSeconds: TimeInterval?
    ) {
        guard inputFormat.sampleRate > 0 else {
            Log.audio.warning("AudioMixer: Invalid input format - sampleRate=\(inputFormat.sampleRate)")
            return
        }

        let frameCount = buffer.frameLength
        guard frameCount > 0 else { return }

        guard let safeCopiedBuffer = copyAudioBuffer(buffer, inputFormat: inputFormat, frameCount: frameCount) else {
            Log.audio.warning("AudioMixer: Failed to copy buffer from \(source.rawValue)")
            return
        }

        let sourceKey = (source == .microphone) ? "mic" : "system"
        let formatKey = "\(sourceKey)-\(inputFormat.sampleRate)-\(inputFormat.channelCount)-\(inputFormat.commonFormat.rawValue)-\(inputFormat.isInterleaved)"

        writeQueue.async { [weak self] in
            guard let self, let audioFile = self.audioFile, (self.isRecording || self.isStopping) else { return }

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
                Log.audio.info("AudioMixer: Created converter for \(source.rawValue) - input: sampleRate=\(inputFormat.sampleRate), ch=\(inputFormat.channelCount), format=\(inputFormat.commonFormat.rawValue), interleaved=\(inputFormat.isInterleaved) -> output: sampleRate=\(fileProcessingFormat.sampleRate), ch=\(fileProcessingFormat.channelCount), format=\(fileProcessingFormat.commonFormat.rawValue), interleaved=\(fileProcessingFormat.isInterleaved)")
            }

            let ratio = fileProcessingFormat.sampleRate / inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio) + 32
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
                    Log.audio.error("AudioMixer: Conversion error from \(source.rawValue) - \(error.localizedDescription)")
                }
                return
            }

            guard status != .error else {
                Log.audio.warning("AudioMixer: Converter returned error status from \(source.rawValue)")
                return
            }

            guard outputBuffer.frameLength > 0 else {
                return
            }

            self.enqueueConvertedSamples(
                outputBuffer,
                source: source,
                timestampSeconds: sourceTimestampSeconds,
                fileProcessingFormat: fileProcessingFormat
            )
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
        timestampSeconds: TimeInterval?,
        fileProcessingFormat: AVAudioFormat
    ) {
        guard let monoSamples = extractMonoFloatSamples(from: buffer), !monoSamples.isEmpty else {
            Log.audio.warning("AudioMixer: Failed to extract converted samples from \(source.rawValue)")
            return
        }

        let startFrame = assignStartFrame(
            for: source,
            timestampSeconds: timestampSeconds,
            sampleCount: monoSamples.count
        )

        let droppedFrames: Int
        let now = Date()

        switch source {
        case .microphone:
            droppedFrames = micRingBuffer.append(startFrame: startFrame, samples: monoSamples)
            lastMicChunkEnqueueTime = now
            if droppedFrames > 0 {
                telemetry.micOverflowFrames += Int64(droppedFrames)
            }
        case .system:
            droppedFrames = systemRingBuffer.append(startFrame: startFrame, samples: monoSamples)
            lastSystemChunkEnqueueTime = now
            if droppedFrames > 0 {
                telemetry.systemOverflowFrames += Int64(droppedFrames)
            }
        }

        updateSyncTelemetry()
        mixAndWriteAvailableFrames(fileProcessingFormat: fileProcessingFormat, flush: false)
        logTelemetryIfNeeded(force: false)
    }

    private func assignStartFrame(
        for source: Source,
        timestampSeconds: TimeInterval?,
        sampleCount: Int
    ) -> Int64 {
        switch source {
        case .microphone:
            return assignStartFrame(
                for: source,
                timeline: &micTimeline,
                timestampSeconds: timestampSeconds,
                sampleCount: sampleCount
            )
        case .system:
            return assignStartFrame(
                for: source,
                timeline: &systemTimeline,
                timestampSeconds: timestampSeconds,
                sampleCount: sampleCount
            )
        }
    }

    private func assignStartFrame(
        for source: Source,
        timeline: inout SourceTimelineState,
        timestampSeconds: TimeInterval?,
        sampleCount: Int
    ) -> Int64 {
        let sampleFrames = Int64(sampleCount)

        let startFrame: Int64
        if let timestampSeconds, timestampSeconds.isFinite {
            if timeline.firstTimestampSeconds == nil {
                timeline.firstTimestampSeconds = timestampSeconds
                timeline.startFrameOffset = initialFrameOffset(for: source)
            }

            let origin = timeline.firstTimestampSeconds ?? timestampSeconds
            let localFrame = Int64(max(0, (timestampSeconds - origin) * outputSampleRate))
            let candidateFrame = timeline.startFrameOffset + localFrame
            startFrame = max(candidateFrame, timeline.nextFrameEstimate)
        } else {
            if timeline.nextFrameEstimate == 0 {
                timeline.startFrameOffset = initialFrameOffset(for: source)
            }
            startFrame = max(timeline.startFrameOffset, timeline.nextFrameEstimate)
        }

        timeline.nextFrameEstimate = startFrame + sampleFrames
        return startFrame
    }

    private func initialFrameOffset(for source: Source) -> Int64 {
        switch source {
        case .microphone:
            return max(systemTimeline.nextFrameEstimate, mixCursorFrame)
        case .system:
            return max(micTimeline.nextFrameEstimate, mixCursorFrame)
        }
    }

    private func updateSyncTelemetry() {
        guard let micLatest = micRingBuffer.latestFrame,
              let systemLatest = systemRingBuffer.latestFrame
        else {
            return
        }

        let delta = abs(micLatest - systemLatest)
        telemetry.maxInterSourceFrameDelta = max(telemetry.maxInterSourceFrameDelta, delta)
    }

    private func initializeMixCursorIfNeeded() {
        guard !hasInitializedMixCursor else { return }

        let earliestSystem = systemRingBuffer.earliestFrame
        let earliestMic = micRingBuffer.earliestFrame

        if includeMicrophoneInMix {
            if let earliestSystem, let earliestMic {
                mixCursorFrame = min(earliestSystem, earliestMic)
                hasInitializedMixCursor = true
                return
            }

            // If one source stalls at start, don't block output forever.
            if let earliestSystem, isSourceStalled(.microphone) {
                mixCursorFrame = earliestSystem
                hasInitializedMixCursor = true
                return
            }

            if let earliestMic, isSourceStalled(.system) {
                mixCursorFrame = earliestMic
                hasInitializedMixCursor = true
                return
            }

            return
        }

        if let earliestSystem {
            mixCursorFrame = earliestSystem
            hasInitializedMixCursor = true
        }
    }

    private func mixAndWriteAvailableFrames(fileProcessingFormat: AVAudioFormat, flush: Bool) {
        guard let audioFile else { return }

        initializeMixCursorIfNeeded()
        guard hasInitializedMixCursor else { return }

        guard let mixEndFrame = calculateMixEndFrame(flush: flush) else { return }
        guard mixEndFrame > mixCursorFrame else { return }

        var wroteAnyData = false

        while mixCursorFrame < mixEndFrame {
            let remainingFrames = Int(mixEndFrame - mixCursorFrame)
            let framesToWrite = flush ? min(mixQuantumFrames, remainingFrames) : mixQuantumFrames

            if framesToWrite <= 0 {
                break
            }

            if !flush, remainingFrames < framesToWrite {
                break
            }

            var micFrameData = [Float](repeating: 0, count: framesToWrite)
            var systemFrameData = [Float](repeating: 0, count: framesToWrite)

            let micFilledFrames: Int
            if includeMicrophoneInMix {
                micFilledFrames = micRingBuffer.fill(rangeStart: mixCursorFrame, destination: &micFrameData)
                if micFilledFrames < framesToWrite {
                    telemetry.micUnderflowFrames += Int64(framesToWrite - micFilledFrames)
                }
            } else {
                micFilledFrames = framesToWrite
            }

            let systemFilledFrames = systemRingBuffer.fill(rangeStart: mixCursorFrame, destination: &systemFrameData)
            if systemFilledFrames < framesToWrite {
                telemetry.systemUnderflowFrames += Int64(framesToWrite - systemFilledFrames)
            }

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
                    let micSample = includeMicrophoneInMix ? micFrameData[index] : 0
                    let systemSample = systemFrameData[index]
                    out[index] = clamp((micSample + systemSample) * mixNormalization)
                }
            } else if let out = outputBuffer.int16ChannelData?[0] {
                for index in 0 ..< framesToWrite {
                    let micSample = includeMicrophoneInMix ? micFrameData[index] : 0
                    let systemSample = systemFrameData[index]
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
                    NSLog("[Diduny] AudioMixer: Started writing mixed audio data")
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

            telemetry.mixedFramesWritten += Int64(framesToWrite)
            telemetry.quantumCount += 1

            mixCursorFrame += Int64(framesToWrite)

            let discardFrame = max(0, mixCursorFrame - Int64(ringDiscardGuardFrames))
            micRingBuffer.discard(upToFrame: discardFrame)
            systemRingBuffer.discard(upToFrame: discardFrame)

            wroteAnyData = true
        }

        if wroteAnyData {
            logTelemetryIfNeeded(force: flush)
        }
    }

    private func calculateMixEndFrame(flush: Bool) -> Int64? {
        let systemLatest = systemRingBuffer.latestFrame
        let micLatest = micRingBuffer.latestFrame

        if flush {
            var latestFrame = systemLatest ?? mixCursorFrame
            if includeMicrophoneInMix {
                latestFrame = max(latestFrame, micLatest ?? mixCursorFrame)
            }
            return latestFrame
        }

        let lookaheadFrames = Int64(mixLookaheadFrames)

        if includeMicrophoneInMix {
            switch (systemLatest, micLatest) {
            case let (systemEnd?, micEnd?):
                return max(mixCursorFrame, min(systemEnd, micEnd) - lookaheadFrames)
            case let (systemEnd?, nil):
                if isSourceStalled(.microphone) {
                    return max(mixCursorFrame, systemEnd - lookaheadFrames)
                }
                return nil
            case let (nil, micEnd?):
                if isSourceStalled(.system) {
                    return max(mixCursorFrame, micEnd - lookaheadFrames)
                }
                return nil
            case (nil, nil):
                return nil
            }
        }

        guard let systemLatest else { return nil }
        return max(mixCursorFrame, systemLatest - lookaheadFrames)
    }

    private func isSourceStalled(_ source: Source) -> Bool {
        let now = Date()

        let lastEnqueueTime: Date?
        switch source {
        case .microphone:
            lastEnqueueTime = lastMicChunkEnqueueTime
        case .system:
            lastEnqueueTime = lastSystemChunkEnqueueTime
        }

        if let lastEnqueueTime {
            return now.timeIntervalSince(lastEnqueueTime) > sourceStallThreshold
        }

        guard let startTime else { return false }
        return now.timeIntervalSince(startTime) > sourceStallThreshold
    }

    private func logTelemetryIfNeeded(force: Bool) {
        let now = Date()

        if !force, now.timeIntervalSince(lastTelemetryLogTime) < telemetryLogInterval {
            return
        }

        if !force, telemetry == lastTelemetrySnapshot {
            return
        }

        let maxDeltaMs = (Double(telemetry.maxInterSourceFrameDelta) / outputSampleRate) * 1000.0
        let micUnderflow = telemetry.micUnderflowFrames
        let systemUnderflow = telemetry.systemUnderflowFrames
        let micOverflow = telemetry.micOverflowFrames
        let systemOverflow = telemetry.systemOverflowFrames
        let mixedFrames = telemetry.mixedFramesWritten
        let quantumCount = telemetry.quantumCount
        Log.audio.info(
            "AudioMixer telemetry: underflow(mic=\(micUnderflow), system=\(systemUnderflow)), overflow(mic=\(micOverflow), system=\(systemOverflow)), mixedFrames=\(mixedFrames), quanta=\(quantumCount), maxDeltaMs=\(maxDeltaMs)"
        )

        lastTelemetrySnapshot = telemetry
        lastTelemetryLogTime = now
    }

    private func microphoneTimestampSeconds(from when: AVAudioTime?) -> TimeInterval? {
        guard let when else { return nil }

        if when.isHostTimeValid {
            return AVAudioTime.seconds(forHostTime: when.hostTime)
        }

        if when.isSampleTimeValid {
            let sampleRate = when.sampleRate > 0 ? when.sampleRate : outputSampleRate
            return Double(when.sampleTime) / sampleRate
        }

        return nil
    }

    private func systemTimestampSeconds(from sampleBuffer: CMSampleBuffer) -> TimeInterval? {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else { return nil }

        let seconds = CMTimeGetSeconds(presentationTime)
        guard seconds.isFinite else { return nil }
        return seconds
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

        // Prevent new buffers from being accepted at entry points while
        // still allowing already-queued async blocks to finish processing.
        isStopping = true

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
            logTelemetryIfNeeded(force: true)
        }

        isRecording = false
        isStopping = false

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
        lastMicChunkEnqueueTime = nil
        lastSystemChunkEnqueueTime = nil
        systemAudioBufferCount = 0

        converterCache.removeAll()
        micRingBuffer.reset()
        systemRingBuffer.reset()
        micTimeline.reset()
        systemTimeline.reset()
        mixCursorFrame = 0
        hasInitializedMixCursor = false

        telemetry = MixerTelemetry()
        lastTelemetrySnapshot = MixerTelemetry()

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
