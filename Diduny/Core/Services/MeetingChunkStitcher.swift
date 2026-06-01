import AVFoundation
import Foundation
import os

/// Stitches an ordered list of WAV chunk files into a single WAV file.
///
/// **RLR-M4:** post-rotation assembler. Called by `MeetingRecorderService.stopRecording()`
/// after all chunks are closed and by the future M5a recovery flow to materialize
/// recovered orphan sessions.
///
/// **Format assumption:** all chunks share the same sample rate / channel layout, which is
/// true for chunks produced by `SystemAudioCaptureService` (16 kHz mono 16-bit). The first
/// readable chunk determines the output format; later chunks with mismatched formats are
/// skipped (and listed in `Result.skippedChunks`). ADR-0009 OQ-2B (heterogeneous chunks)
/// is out of scope for M3b/M4 — `SystemAudioCaptureService` only emits one format.
///
/// **Performance:** sequential `AVAudioFile` read/write. PoC ballpark for 24 × 5-min chunks:
/// median 1480 ms, p95 2127 ms. Caller should run on a background queue.
enum MeetingChunkStitcher {

    // MARK: - Types

    struct Result {
        /// The stitched output file. Matches the URL passed to `stitch`.
        let outputURL: URL
        /// Total audio duration written (seconds, derived from frames / sampleRate).
        let totalDurationSeconds: Double
        /// 1-based indices of chunks that could not be read or had an incompatible format.
        /// Empty when stitching was perfect.
        let skippedChunks: [Int]
        /// Number of chunks that were successfully appended.
        let appendedChunkCount: Int
    }

    enum StitchError: LocalizedError {
        case noChunks
        case allChunksUnreadable
        case writerSetupFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noChunks: "No chunks were provided for stitching."
            case .allChunksUnreadable: "None of the recorded chunks could be read."
            case let .writerSetupFailed(error): "Failed to open output audio file: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Public API

    /// Stitches `chunkURLs` into `outputURL` in order. Throws if no chunk is readable.
    ///
    /// Fast path: when `chunkURLs.count == 1`, the lone chunk is copied to `outputURL`
    /// (no decode/encode cycle) — this is the common case for short meetings that did
    /// not cross the rotation boundary.
    static func stitch(chunkURLs: [URL], outputURL: URL) throws -> Result {
        guard !chunkURLs.isEmpty else { throw StitchError.noChunks }

        // Pre-clean output if it exists from a previous attempt.
        try? FileManager.default.removeItem(at: outputURL)

        // Single-chunk fast path: copy instead of decode/encode.
        if chunkURLs.count == 1 {
            return try stitchSingleChunk(chunkURLs[0], outputURL: outputURL)
        }

        return try stitchMultiple(chunkURLs: chunkURLs, outputURL: outputURL)
    }

    // MARK: - Single-Chunk Path

    private static func stitchSingleChunk(_ chunkURL: URL, outputURL: URL) throws -> Result {
        // Try to compute duration before deciding whether to copy or signal empty.
        var duration: Double = 0
        if let file = try? AVAudioFile(forReading: chunkURL), file.fileFormat.sampleRate > 0 {
            duration = Double(file.length) / file.fileFormat.sampleRate
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: chunkURL.path) else {
            throw StitchError.allChunksUnreadable
        }
        try fm.copyItem(at: chunkURL, to: outputURL)

        return Result(
            outputURL: outputURL,
            totalDurationSeconds: duration,
            skippedChunks: duration > 0 ? [] : [1],
            appendedChunkCount: duration > 0 ? 1 : 0
        )
    }

    // MARK: - Multi-Chunk Path

    private static func stitchMultiple(chunkURLs: [URL], outputURL: URL) throws -> Result {
        var skipped: [Int] = []
        var firstReadable: AVAudioFile?
        var firstReadableIndex = 0

        // Locate first readable chunk; it defines output format.
        for (idx, url) in chunkURLs.enumerated() {
            if let file = try? AVAudioFile(forReading: url), file.length > 0 {
                firstReadable = file
                firstReadableIndex = idx
                break
            }
            skipped.append(idx + 1)
            Log.audio.warning("[Stitch] chunk \(idx + 1) at \(url.lastPathComponent) unreadable or empty")
        }

        guard let firstFile = firstReadable else {
            throw StitchError.allChunksUnreadable
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: firstFile.fileFormat.sampleRate,
            AVNumberOfChannelsKey: Int(firstFile.fileFormat.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
        } catch {
            throw StitchError.writerSetupFailed(error)
        }

        var totalFrames: AVAudioFramePosition = 0
        var appendedCount = 0

        // Append the first readable chunk.
        do {
            try appendFile(firstFile, into: outputFile, totalFrames: &totalFrames)
            appendedCount += 1
        } catch {
            Log.audio.warning("[Stitch] chunk \(firstReadableIndex + 1) read failed mid-append: \(error.localizedDescription)")
            skipped.append(firstReadableIndex + 1)
        }

        // Append the rest.
        if firstReadableIndex + 1 < chunkURLs.count {
            for idx in (firstReadableIndex + 1) ..< chunkURLs.count {
                let url = chunkURLs[idx]
                let chunkNumber = idx + 1
                do {
                    let file = try AVAudioFile(forReading: url)
                    guard file.length > 0 else {
                        skipped.append(chunkNumber)
                        Log.audio.warning("[Stitch] chunk \(chunkNumber) is empty")
                        continue
                    }
                    guard file.fileFormat.sampleRate == firstFile.fileFormat.sampleRate,
                          file.fileFormat.channelCount == firstFile.fileFormat.channelCount
                    else {
                        skipped.append(chunkNumber)
                        Log.audio.warning(
                            "[Stitch] chunk \(chunkNumber) format mismatch (\(file.fileFormat) vs \(firstFile.fileFormat))"
                        )
                        continue
                    }
                    try appendFile(file, into: outputFile, totalFrames: &totalFrames)
                    appendedCount += 1
                } catch {
                    skipped.append(chunkNumber)
                    Log.audio.warning("[Stitch] chunk \(chunkNumber) failed: \(error.localizedDescription)")
                }
            }
        }

        let totalDuration = outputFile.fileFormat.sampleRate > 0
            ? Double(totalFrames) / outputFile.fileFormat.sampleRate
            : 0

        Log.audio.info(
            "[Stitch] wrote \(appendedCount)/\(chunkURLs.count) chunks (\(String(format: "%.1f", totalDuration))s) skipped=\(skipped)"
        )

        return Result(
            outputURL: outputURL,
            totalDurationSeconds: totalDuration,
            skippedChunks: skipped,
            appendedChunkCount: appendedCount
        )
    }

    // MARK: - Helpers

    /// Streams `source` into `destination` in fixed-size buffers; updates `totalFrames` running counter.
    private static func appendFile(
        _ source: AVAudioFile,
        into destination: AVAudioFile,
        totalFrames: inout AVAudioFramePosition
    ) throws {
        let bufferFrames: AVAudioFrameCount = 32_768
        let processingFormat = source.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: bufferFrames) else {
            return
        }

        while source.framePosition < source.length {
            let remaining = source.length - source.framePosition
            let toRead = min(AVAudioFrameCount(remaining), bufferFrames)
            buffer.frameLength = 0
            try source.read(into: buffer, frameCount: toRead)
            if buffer.frameLength == 0 { break }
            try destination.write(from: buffer)
            totalFrames += AVAudioFramePosition(buffer.frameLength)
        }
    }
}
