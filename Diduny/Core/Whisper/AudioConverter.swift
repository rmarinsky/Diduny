import AVFoundation
import Foundation

enum AudioConverter {
    static let whisperSampleRate: Double = 16000.0

    static func convertToWhisperFormat(audioData: Data) throws -> [Float] {
        let tempFileExtension = detectedAudioFileExtension(for: audioData)

        // Write audio data to a temp file so AVAudioFile can read it
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(tempFileExtension)

        defer { try? FileManager.default.removeItem(at: tempURL) }

        try audioData.write(to: tempURL)

        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: tempURL)
        } catch {
            Log.whisper.error("Failed to open audio file: \(error.localizedDescription)")
            throw WhisperError.audioConversionFailed
        }

        let sourceFormat = sourceFile.processingFormat
        let sourceFrameCount = AVAudioFrameCount(sourceFile.length)

        Log.whisper.info(
            "Source audio: \(sourceFormat.sampleRate)Hz, \(sourceFormat.channelCount)ch, \(sourceFrameCount) frames"
        )

        // Target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: whisperSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw WhisperError.audioConversionFailed
        }

        // If source is already 16kHz mono Float32, read directly
        if sourceFormat.sampleRate == whisperSampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: sourceFrameCount
            ) else {
                throw WhisperError.audioConversionFailed
            }
            try sourceFile.read(into: buffer)
            return bufferToFloatArray(buffer)
        }

        // Need conversion
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            Log.whisper.error("Failed to create audio converter")
            throw WhisperError.audioConversionFailed
        }

        // Calculate output frame count
        let ratio = whisperSampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(ceil(Double(sourceFrameCount) * ratio))

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else {
            throw WhisperError.audioConversionFailed
        }

        // Read source into buffer
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: sourceFrameCount
        ) else {
            throw WhisperError.audioConversionFailed
        }
        try sourceFile.read(into: sourceBuffer)

        // Convert
        var error: NSError?
        var allConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let error {
            Log.whisper.error("Audio conversion failed: \(error.localizedDescription)")
            throw WhisperError.audioConversionFailed
        }

        let samples = bufferToFloatArray(outputBuffer)
        Log.whisper.info("Converted to \(samples.count) samples at \(whisperSampleRate)Hz")
        return samples
    }

    private static func bufferToFloatArray(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    private static func detectedAudioFileExtension(for audioData: Data) -> String {
        guard audioData.count >= 12 else {
            return "wav"
        }

        let bytes = [UInt8](audioData.prefix(12))

        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45
        {
            return "wav"
        }

        if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 {
            return "flac"
        }

        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return "m4a"
        }

        if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) ||
            (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)
        {
            return "mp3"
        }

        if bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 {
            return "ogg"
        }

        return "wav"
    }
}
