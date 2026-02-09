import AVFoundation
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

@available(macOS 13.0, *)
final class SystemAudioCaptureService: NSObject {
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var isCapturing = false
    private var outputFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    private var sampleCount: Int = 0
    private var lastFlushTime: Date = Date()
    private let flushInterval: TimeInterval = 30.0 // Flush to disk every 30 seconds

    var includeMicrophone: Bool = false
    var onError: ((Error) -> Void)?
    var onCaptureStarted: (() -> Void)?

    /// Callback mode: when set, raw sample buffers are forwarded instead of writing to file
    var onAudioBuffer: ((CMSampleBuffer) -> Void)?

    /// Whether to use callback mode (forwarding buffers) instead of file writing
    var useCallbackMode: Bool = false

    /// Secondary callback for raw PCM data (fires in both file-write and callback modes)
    var onRawAudioData: ((Data) -> Void)?
    private var rawAudioCallbackCount = 0

    // MARK: - Permission Check

    static func checkPermission() async -> Bool {
        do {
            // This will prompt for permission if not granted
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return !content.displays.isEmpty
        } catch {
            Log.audio.error("Permission check failed: \(error)")
            return false
        }
    }

    static func requestPermission() async -> Bool {
        // Requesting shareable content triggers the permission dialog
        await checkPermission()
    }

    // MARK: - Start Capture

    func startCapture(to outputURL: URL) async throws {
        guard !isCapturing else {
            Log.audio.warning("Already capturing")
            return
        }

        self.outputURL = outputURL

        Log.audio.info("Starting system audio capture...")

        // Get shareable content
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplayFound
        }

        // Create filter for audio only (capture display but we only want audio)
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Configure stream for audio capture
        // Use lower quality for long recordings to reduce memory pressure
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // Minimal video
        config.showsCursor = false
        config.sampleRate = 16000 // Reduced from 48000 for long recordings
        config.channelCount = 1 // Mono instead of stereo to save memory

        // Create stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)

        guard let stream else {
            throw SystemAudioError.streamCreationFailed
        }

        // Add audio output
        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "ua.com.rmarinsky.diduny.systemaudio")
        )

        // Setup audio file for recording (only if not in callback mode)
        if !useCallbackMode {
            try setupAudioFile(at: outputURL)
        }

        // Start capture
        try await stream.startCapture()
        isCapturing = true
        lastFlushTime = Date() // Reset flush timer

        Log.audio.info("Capture started successfully (16kHz mono for long recordings)")
        onCaptureStarted?()
    }

    // MARK: - Stop Capture

    func stopCapture() async throws -> URL? {
        guard isCapturing, let stream else {
            Log.audio.warning("Not capturing")
            return nil
        }

        Log.audio.info("Stopping capture... Total samples processed: \(self.sampleCount)")

        try await stream.stopCapture()
        self.stream = nil
        isCapturing = false

        // Close audio file and cleanup
        audioFile = nil
        audioConverter = nil
        outputFormat = nil
        sampleCount = 0

        Log.audio.info("Capture stopped, file saved to: \(self.outputURL?.path ?? "nil")")

        return outputURL
    }

    // MARK: - Audio File Setup

    private func setupAudioFile(at url: URL) throws {
        // Use lower quality 16-bit PCM for long recordings to reduce memory usage
        // This is ~12x smaller than 48kHz stereo 32-bit float
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0, // Lower sample rate for meetings
            AVNumberOfChannelsKey: 1, // Mono for speech
            AVLinearPCMBitDepthKey: 16, // 16-bit instead of 32-bit float
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        // Create output format for conversion
        outputFormat = AVAudioFormat(settings: settings)

        audioFile = try AVAudioFile(forWriting: url, settings: settings)

        Log.audio.info("Audio file created at: \(url.path) (16kHz mono 16-bit for long recordings)")
    }
}

// MARK: - SCStreamDelegate

@available(macOS 13.0, *)
extension SystemAudioCaptureService: SCStreamDelegate {
    func stream(_: SCStream, didStopWithError error: Error) {
        Log.audio.error("Stream stopped with error: \(error)")
        isCapturing = false
        onError?(error)
    }
}

// MARK: - SCStreamOutput

@available(macOS 13.0, *)
extension SystemAudioCaptureService: SCStreamOutput {
    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Stream raw PCM data to real-time transcription (fires in both modes)
        if let onRawAudioData {
            if let data = extractRawPCMData(from: sampleBuffer) {
                rawAudioCallbackCount += 1
                if rawAudioCallbackCount <= 5 || rawAudioCallbackCount % 200 == 0 {
                    NSLog("[AudioCapture] onRawAudioData callback #%d, data size=%d bytes", rawAudioCallbackCount, data.count)
                }
                onRawAudioData(data)
            }
        } else if sampleCount <= 3 {
            NSLog("[AudioCapture] onRawAudioData is nil — real-time streaming not wired")
        }

        // Callback mode: forward buffer to mixer
        if useCallbackMode {
            onAudioBuffer?(sampleBuffer)
            return
        }

        // File writing mode
        guard let audioFile else { return }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return
        }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return }

        logSampleInfoIfNeeded(asbd: asbd, numSamples: numSamples)

        guard let pcmBuffer = createPCMBuffer(from: sampleBuffer, asbd: asbd, numSamples: numSamples) else {
            return
        }

        writeBufferToFile(pcmBuffer, audioFile: audioFile, numSamples: numSamples)
    }

    // MARK: - Helper Methods

    private func logSampleInfoIfNeeded(
        asbd: UnsafePointer<AudioStreamBasicDescription>,
        numSamples: Int
    ) {
        sampleCount += 1
        guard sampleCount <= 3 else { return }

        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let logMessage = "Audio sample \(sampleCount): frames=\(numSamples), " +
            "sampleRate=\(asbd.pointee.mSampleRate), channels=\(asbd.pointee.mChannelsPerFrame), " +
            "bitsPerChannel=\(asbd.pointee.mBitsPerChannel), isFloat=\(isFloat), " +
            "isNonInterleaved=\(isNonInterleaved)"
        Log.audio.info("\(logMessage)")
    }

    private func createPCMBuffer(
        from sampleBuffer: CMSampleBuffer,
        asbd: UnsafePointer<AudioStreamBasicDescription>,
        numSamples: Int
    ) -> AVAudioPCMBuffer? {
        guard let inputFormat = AVAudioFormat(streamDescription: asbd) else {
            Log.audio.error("Failed to create input format")
            return nil
        }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(numSamples)
        ) else {
            Log.audio.error("Failed to create PCM buffer")
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            Log.audio.error("Failed to get data buffer")
            return nil
        }

        guard let dataPointer = getDataPointer(from: blockBuffer) else {
            return nil
        }

        copyAudioData(to: pcmBuffer, from: dataPointer, asbd: asbd, numSamples: numSamples)
        return pcmBuffer
    }

    private func extractRawPCMData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let ptr = dataPointer, totalLength > 0 else {
            return nil
        }

        // ScreenCaptureKit outputs 32-bit float PCM, but Soniox expects s16le (16-bit signed int).
        // Convert float32 samples to int16 samples.
        let floatCount = totalLength / MemoryLayout<Float>.size
        guard floatCount > 0 else { return nil }

        let floatPointer = UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: floatCount)

        var int16Data = Data(count: floatCount * MemoryLayout<Int16>.size)
        int16Data.withUnsafeMutableBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0 ..< floatCount {
                let clamped = max(-1.0, min(1.0, floatPointer[i]))
                int16Buffer[i] = Int16(clamped * Float(Int16.max))
            }
        }

        return int16Data
    }

    private func getDataPointer(from blockBuffer: CMBlockBuffer) -> UnsafeMutablePointer<Int8>? {
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
            Log.audio.error("Failed to get data pointer, status: \(status)")
            return nil
        }
        return data
    }

    private func copyAudioData(
        to pcmBuffer: AVAudioPCMBuffer,
        from data: UnsafeMutablePointer<Int8>,
        asbd: UnsafePointer<AudioStreamBasicDescription>,
        numSamples: Int
    ) {
        let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if isNonInterleaved {
            copyNonInterleavedData(to: pcmBuffer, from: data, asbd: asbd, numSamples: numSamples)
        } else {
            copyInterleavedData(to: pcmBuffer, from: data, asbd: asbd, numSamples: numSamples)
        }
    }

    private func copyNonInterleavedData(
        to pcmBuffer: AVAudioPCMBuffer,
        from data: UnsafeMutablePointer<Int8>,
        asbd: UnsafePointer<AudioStreamBasicDescription>,
        numSamples: Int
    ) {
        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)

        guard let floatChannelData = pcmBuffer.floatChannelData else { return }

        for channel in 0 ..< channelCount {
            let channelOffset = channel * numSamples * bytesPerFrame
            let srcPtr = data.advanced(by: channelOffset)
            let dstPtr = floatChannelData[channel]
            memcpy(dstPtr, srcPtr, numSamples * bytesPerFrame)
        }
    }

    private func copyInterleavedData(
        to pcmBuffer: AVAudioPCMBuffer,
        from data: UnsafeMutablePointer<Int8>,
        asbd: UnsafePointer<AudioStreamBasicDescription>,
        numSamples: Int
    ) {
        guard let floatChannelData = pcmBuffer.floatChannelData else { return }

        let srcPtr = UnsafeRawPointer(data)
        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        let bytesPerSample = Int(asbd.pointee.mBitsPerChannel / 8)

        for frame in 0 ..< numSamples {
            for channel in 0 ..< channelCount {
                let srcOffset = (frame * channelCount + channel) * bytesPerSample
                let value = srcPtr.load(fromByteOffset: srcOffset, as: Float.self)
                floatChannelData[channel][frame] = value
            }
        }
    }

    private func writeBufferToFile(
        _ pcmBuffer: AVAudioPCMBuffer,
        audioFile: AVAudioFile,
        numSamples: Int
    ) {
        do {
            let inputFormat = pcmBuffer.format
            let fileFormat = audioFile.processingFormat

            if inputFormat == fileFormat {
                try audioFile.write(from: pcmBuffer)
            } else {
                try writeWithConversion(pcmBuffer, to: audioFile, numSamples: numSamples)
            }

            // Periodically flush to disk to reduce memory pressure
            let now = Date()
            if now.timeIntervalSince(self.lastFlushTime) >= self.flushInterval {
                // AVAudioFile automatically flushes, but we can log it
                Log.audio.info("Audio buffer auto-flush (every \(self.flushInterval)s to prevent memory issues)")
                self.lastFlushTime = now
            }
        } catch {
            Log.audio.error("Error writing audio: \(error)")
        }
    }

    private func writeWithConversion(
        _ pcmBuffer: AVAudioPCMBuffer,
        to audioFile: AVAudioFile,
        numSamples: Int
    ) throws {
        let fileFormat = audioFile.processingFormat

        if audioConverter == nil {
            audioConverter = AVAudioConverter(from: pcmBuffer.format, to: fileFormat)
        }

        guard let converter = audioConverter else {
            Log.audio.error("Failed to create converter")
            return
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: fileFormat,
            frameCapacity: AVAudioFrameCount(numSamples)
        ) else {
            Log.audio.error("Failed to create output buffer")
            return
        }

        var error: NSError?
        var hasData = true
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return pcmBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if let error {
            Log.audio.error("Conversion error: \(error)")
            return
        }

        if outputBuffer.frameLength > 0 {
            try audioFile.write(from: outputBuffer)
        }
    }
}

// MARK: - Errors

enum SystemAudioError: LocalizedError {
    case noDisplayFound
    case streamCreationFailed
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            "No display found for screen capture"
        case .streamCreationFailed:
            "Failed to create audio capture stream"
        case .permissionDenied:
            "Screen recording permission required"
        }
    }
}
