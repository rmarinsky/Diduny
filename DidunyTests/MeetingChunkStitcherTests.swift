import AVFoundation
import XCTest
@testable import Diduny

/// Tests for `MeetingChunkStitcher` (RLR-M4).
///
/// Strategy: synthesize short mono 16 kHz 16-bit WAV files via `AVAudioFile`, stitch them,
/// then verify duration and frame counts in the output. Each test writes into an isolated
/// temp directory so the user's filesystem stays clean.
final class MeetingChunkStitcherTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingChunkStitcherTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Writes a WAV chunk filled with constant-amplitude samples; returns its URL.
    private func writeChunk(name: String, durationSeconds: Double, sampleRate: Double = 16000) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount = AVAudioFrameCount(durationSeconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            XCTFail("Failed to create PCM buffer")
            return url
        }
        buffer.frameLength = frameCount
        if let data = buffer.floatChannelData?[0] {
            for i in 0 ..< Int(frameCount) {
                data[i] = 0.05 // small constant amplitude so silence detectors don't kick in
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// Creates a zero-byte file masquerading as a chunk (corrupt / empty).
    private func writeEmptyFile(name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    // MARK: - 1. noChunks throws

    func test_stitch_emptyList_throws() {
        let target = tmpDir.appendingPathComponent("out.wav")
        XCTAssertThrowsError(try MeetingChunkStitcher.stitch(chunkURLs: [], outputURL: target)) { error in
            guard case MeetingChunkStitcher.StitchError.noChunks = error else {
                XCTFail("Expected .noChunks, got \(error)")
                return
            }
        }
    }

    // MARK: - 2. single-chunk fast path copies

    func test_stitch_singleChunk_copiesAndReturnsDuration() throws {
        let chunk = try writeChunk(name: "chunk_001.wav", durationSeconds: 1.0)
        let target = tmpDir.appendingPathComponent("out.wav")

        let result = try MeetingChunkStitcher.stitch(chunkURLs: [chunk], outputURL: target)

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(result.appendedChunkCount, 1)
        XCTAssertTrue(result.skippedChunks.isEmpty)
        XCTAssertEqual(result.totalDurationSeconds, 1.0, accuracy: 0.05)

        // Source must still exist (we copy, not move).
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path))
    }

    // MARK: - 3. multi-chunk stitch sums duration

    func test_stitch_threeChunks_durationIsSum() throws {
        let c1 = try writeChunk(name: "chunk_001.wav", durationSeconds: 1.0)
        let c2 = try writeChunk(name: "chunk_002.wav", durationSeconds: 0.5)
        let c3 = try writeChunk(name: "chunk_003.wav", durationSeconds: 0.7)
        let target = tmpDir.appendingPathComponent("out.wav")

        let result = try MeetingChunkStitcher.stitch(chunkURLs: [c1, c2, c3], outputURL: target)

        XCTAssertEqual(result.appendedChunkCount, 3)
        XCTAssertTrue(result.skippedChunks.isEmpty)
        XCTAssertEqual(result.totalDurationSeconds, 2.2, accuracy: 0.1)

        // Verify the output is a readable WAV with the expected frame count.
        let outFile = try AVAudioFile(forReading: target)
        let expectedFrames = AVAudioFramePosition(2.2 * 16000)
        XCTAssertEqual(Int(outFile.length), Int(expectedFrames), accuracy: 1600) // ±0.1s tolerance
    }

    // MARK: - 4. skip empty chunk in the middle

    func test_stitch_skipsEmptyChunk() throws {
        let c1 = try writeChunk(name: "chunk_001.wav", durationSeconds: 0.5)
        let cBad = try writeEmptyFile(name: "chunk_002.wav")
        let c3 = try writeChunk(name: "chunk_003.wav", durationSeconds: 0.5)
        let target = tmpDir.appendingPathComponent("out.wav")

        let result = try MeetingChunkStitcher.stitch(chunkURLs: [c1, cBad, c3], outputURL: target)

        XCTAssertEqual(result.appendedChunkCount, 2)
        XCTAssertEqual(result.skippedChunks, [2])
        XCTAssertEqual(result.totalDurationSeconds, 1.0, accuracy: 0.1)
    }

    // MARK: - 5. allChunksUnreadable error

    func test_stitch_allChunksEmpty_throwsAllUnreadable() throws {
        let bad1 = try writeEmptyFile(name: "chunk_001.wav")
        let bad2 = try writeEmptyFile(name: "chunk_002.wav")
        let target = tmpDir.appendingPathComponent("out.wav")

        XCTAssertThrowsError(try MeetingChunkStitcher.stitch(chunkURLs: [bad1, bad2], outputURL: target)) { error in
            guard case MeetingChunkStitcher.StitchError.allChunksUnreadable = error else {
                XCTFail("Expected .allChunksUnreadable, got \(error)")
                return
            }
        }
    }

    // MARK: - 6. skip leading empty chunk

    func test_stitch_leadingEmptyChunk_skippedFirstReadableDefinesFormat() throws {
        let bad = try writeEmptyFile(name: "chunk_001.wav")
        let c2 = try writeChunk(name: "chunk_002.wav", durationSeconds: 0.5)
        let target = tmpDir.appendingPathComponent("out.wav")

        let result = try MeetingChunkStitcher.stitch(chunkURLs: [bad, c2], outputURL: target)

        XCTAssertEqual(result.appendedChunkCount, 1)
        XCTAssertEqual(result.skippedChunks, [1])
        XCTAssertEqual(result.totalDurationSeconds, 0.5, accuracy: 0.1)
    }
}
