import AVFoundation
import Foundation

/// Converts imported media into a compact audio-only file before it can cross
/// the app's network boundary.
final class ImportedMediaAudioPreparer {
    static let maximumDurationSeconds: TimeInterval = 300 * 60

    struct PreparedAudio {
        let fileURL: URL
        let durationSeconds: TimeInterval

        func removeTemporaryFile() {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    enum PreparationError: LocalizedError, Equatable {
        case noAudioTrack
        case invalidDuration
        case durationLimitExceeded(maximumMinutes: Int)
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                String(localized: "The selected file does not contain an audio track.")
            case .invalidDuration:
                String(localized: "The selected file has an invalid duration.")
            case let .durationLimitExceeded(maximumMinutes):
                String(localized: "The selected file is longer than the \(maximumMinutes)-minute transcription limit.")
            case let .extractionFailed(message):
                String(localized: "Could not extract audio: \(message)")
            }
        }
    }

    private let fileManager: FileManager
    private let temporaryDirectory: URL

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func prepare(sourceURL: URL) async throws -> PreparedAudio {
        try Task.checkCancellation()

        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw PreparationError.noAudioTrack
        }

        // A live recorder can finalize a container whose movie/track/edit-list timeline overstates
        // the real audio (e.g. a 166-minute recording reported as 6+ hours). AVAsset.duration and
        // the track's timeRange both inherit that inflated timeline, so validate the decoded audio
        // samples — the audio that will actually be exported — instead of the container timeline.
        let durationSeconds = try await Self.audioSampleDurationSeconds(asset: asset, track: audioTrack)
        try Self.validate(durationSeconds: durationSeconds)

        let outputURL = temporaryDirectory
            .appendingPathComponent("diduny-import-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        do {
            try await extractAudio(from: asset, to: outputURL)
            try Task.checkCancellation()
            return PreparedAudio(fileURL: outputURL, durationSeconds: durationSeconds)
        } catch {
            try? fileManager.removeItem(at: outputURL)
            if error is CancellationError {
                throw error
            }
            if let preparationError = error as? PreparationError {
                throw preparationError
            }
            throw PreparationError.extractionFailed(error.localizedDescription)
        }
    }

    static func validate(durationSeconds: TimeInterval) throws {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw PreparationError.invalidDuration
        }
        guard durationSeconds <= maximumDurationSeconds else {
            throw PreparationError.durationLimitExceeded(
                maximumMinutes: Int(maximumDurationSeconds / 60)
            )
        }
    }

    /// Duration of the real decoded audio samples, independent of the container's movie/track/
    /// edit-list timeline (which a live recorder can overstate). Reading stops as soon as the
    /// audio is known to exceed the limit, so an over-long file is rejected without scanning all
    /// of it.
    private static func audioSampleDurationSeconds(
        asset: AVAsset,
        track: AVAssetTrack
    ) async throws -> TimeInterval {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw PreparationError.invalidDuration
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? PreparationError.invalidDuration
        }
        defer { reader.cancelReading() }

        let limit = CMTime(seconds: maximumDurationSeconds, preferredTimescale: 600)
        var total = CMTime.zero
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            total = CMTimeAdd(total, sampleDuration(of: sample))
            if total > limit {
                return CMTimeGetSeconds(total)
            }
        }

        if reader.status == .failed {
            throw reader.error ?? PreparationError.invalidDuration
        }
        return CMTimeGetSeconds(total)
    }

    private static func sampleDuration(of sample: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sample)
        if duration.isNumeric, duration.value > 0 {
            return duration
        }
        // Fall back to the frame count when the container omits per-sample durations.
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0,
              let format = CMSampleBufferGetFormatDescription(sample),
              let sampleRate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate,
              sampleRate > 0
        else {
            return .zero
        }
        return CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(sampleRate))
    }

    private func extractAudio(
        from asset: AVAsset,
        to outputURL: URL
    ) async throws {
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw PreparationError.extractionFailed(
                "The selected media format cannot be converted to audio."
            )
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = true

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exporter.exportAsynchronously {
                    switch exporter.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(
                            throwing: PreparationError.extractionFailed(
                                exporter.error?.localizedDescription
                                    ?? "Audio export did not complete."
                            )
                        )
                    }
                }
            }
        } onCancel: {
            exporter.cancelExport()
        }
    }
}
