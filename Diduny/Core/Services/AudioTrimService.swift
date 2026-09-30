import AVFoundation
import Foundation

/// Produces temporary selected audio. The library's original is never modified.
enum AudioTrimService {
    enum PreparationError: Error {
        case invalidRange
        case unreadableAudio
    }

    static func prepareAudio(fileURL: URL, range: AudioTrimRange?) async throws -> URL {
        guard let range else { return fileURL }
        let task = Task.detached(priority: .userInitiated) {
            try export(fileURL: fileURL, range: range)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func export(fileURL: URL, range: AudioTrimRange) throws -> URL {
        try Task.checkCancellation()
        let input = try AVAudioFile(forReading: fileURL)
        let sampleRate = input.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0,
              range.isValid(for: Double(input.length) / sampleRate)
        else { throw PreparationError.invalidRange }
        let start = AVAudioFramePosition((range.startSeconds * sampleRate).rounded())
        let end = min(input.length, AVAudioFramePosition((range.endSeconds * sampleRate).rounded()))
        guard end > start else { throw PreparationError.invalidRange }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("diduny-trim-\(UUID().uuidString).wav")
        do {
            let output = try AVAudioFile(forWriting: destination, settings: input.processingFormat.settings)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 32768)
            else { throw PreparationError.unreadableAudio }
            input.framePosition = start
            var remaining = end - start
            while remaining > 0 {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 32768)))
                guard buffer.frameLength > 0 else { throw PreparationError.unreadableAudio }
                try output.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
            try Task.checkCancellation()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
