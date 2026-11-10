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
            case .noChunks: String(localized: "No chunks were provided for stitching.")
            case .allChunksUnreadable: String(localized: "None of the recorded chunks could be read.")
            case let .writerSetupFailed(error): String(
                    localized: "Failed to open output audio file: \(error.localizedDescription)"
                )
            }
        }
    }

    enum RepairError: LocalizedError {
        case fileTooLarge(String)

        var errorDescription: String? {
            switch self {
            case let .fileTooLarge(name): "\(name) is too large to repair as a WAV file."
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

    // MARK: - Interrupted Chunks

    /// A process killed mid-write leaves the audio on disk but the WAV header claiming no
    /// samples, so `AVAudioFile` reads length 0. Writes a corrected copy to `outputURL` and
    /// returns true; returns false, writing nothing, when the header needs no repair or the
    /// file has no recognisable WAV layout. The source file is never changed. A declared size
    /// that fits the file is trusted: bytes after it are other WAV chunks, not audio.
    static func writeRepairedCopy(of chunkURL: URL, to outputURL: URL) throws -> Bool {
        let (fileSize, layout) = try readLayout(of: chunkURL)
        guard let layout else { return false }
        let available = fileSize - layout.dataOffset
        guard available > 0, layout.declaredDataSize == 0 || layout.declaredDataSize > available else { return false }
        // A WAV header stores sizes in 32 bits.
        guard fileSize <= Int(UInt32.max) else { throw RepairError.fileTooLarge(chunkURL.lastPathComponent) }

        let audioBytes = available / layout.blockAlign * layout.blockAlign
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.copyItem(at: chunkURL, to: outputURL)
        let handle = try FileHandle(forUpdating: outputURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(layout.dataOffset + audioBytes))
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: littleEndianBytes(layout.dataOffset + audioBytes - 8))
        try handle.seek(toOffset: UInt64(layout.dataOffset - 4))
        try handle.write(contentsOf: littleEndianBytes(audioBytes))
        return true
    }

    /// True only when the file provably holds no audio bytes: an empty file, or a WAV header
    /// with nothing after it (a chunk opened by a rotation just before the process died).
    static func hasNoAudio(_ chunkURL: URL) throws -> Bool {
        let (fileSize, layout) = try readLayout(of: chunkURL)
        if fileSize == 0 { return true }
        guard let layout else { return false }
        return fileSize <= layout.dataOffset
    }

    private static func littleEndianBytes(_ value: Int) -> Data {
        withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) }
    }

    private static func readLayout(
        of url: URL
    ) throws -> (fileSize: Int, layout: (dataOffset: Int, declaredDataSize: Int, blockAlign: Int)?) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // The writer pads its header to 4 KB; only the header is ever loaded.
        let header = try handle.read(upToCount: 64 * 1024) ?? Data()
        return (fileSize, wavLayout(of: header))
    }

    private static func wavLayout(of bytes: Data) -> (dataOffset: Int, declaredDataSize: Int, blockAlign: Int)? {
        func tag(at offset: Int) -> String { String(decoding: bytes[offset ..< offset + 4], as: UTF8.self) }
        func uint32(at offset: Int) -> Int {
            (0 ..< 4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        guard bytes.count >= 12, tag(at: 0) == "RIFF", tag(at: 8) == "WAVE" else { return nil }
        var offset = 12
        var blockAlign: Int?
        while offset + 8 <= bytes.count {
            let size = uint32(at: offset + 4)
            let id = tag(at: offset)
            if id == "fmt ", offset + 22 <= bytes.count {
                blockAlign = Int(bytes[offset + 20]) | Int(bytes[offset + 21]) << 8
            } else if id == "data" {
                guard let blockAlign, blockAlign > 0 else { return nil }
                return (offset + 8, size, blockAlign)
            }
            offset += 8 + size + (size % 2)
        }
        return nil
    }

    // MARK: - Single-Chunk Path

    private static func stitchSingleChunk(_ chunkURL: URL, outputURL: URL) throws -> Result {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: chunkURL.path) else {
            throw StitchError.allChunksUnreadable
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: chunkURL)
        } catch {
            Log.audio
                .warning(
                    "[Stitch] single chunk at \(chunkURL.lastPathComponent) unreadable: \(error.localizedDescription)"
                )
            throw StitchError.allChunksUnreadable
        }

        guard file.length > 0, file.fileFormat.sampleRate > 0 else {
            Log.audio.warning("[Stitch] single chunk at \(chunkURL.lastPathComponent) empty or invalid")
            throw StitchError.allChunksUnreadable
        }

        let duration = Double(file.length) / file.fileFormat.sampleRate
        try fileManager.copyItem(at: chunkURL, to: outputURL)

        return Result(
            outputURL: outputURL,
            totalDurationSeconds: duration,
            skippedChunks: [],
            appendedChunkCount: 1
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
            Log.audio
                .warning(
                    "[Stitch] chunk \(firstReadableIndex + 1) read failed mid-append: \(error.localizedDescription)"
                )
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
        let bufferFrames: AVAudioFrameCount = 32768
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
