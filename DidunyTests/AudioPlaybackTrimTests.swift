@testable import Diduny
import AVFoundation
import XCTest

@MainActor
final class AudioPlaybackTrimTests: XCTestCase {
    func testPlaybackUsesSelectedDurationAndClampsSeek() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("playback-trim-\(UUID()).wav")
        defer { AudioPlaybackService.shared.stop(); try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000))
        buffer.frameLength = 32000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 32000)
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let playback = AudioPlaybackService.shared
        playback.stop()
        let id = UUID()
        playback.togglePlayback(recordingId: id, fileURL: url, trimRange: AudioTrimRange(startSeconds: 2, endSeconds: 3))
        XCTAssertEqual(playback.duration, 1, accuracy: 0.001)
        playback.seek(to: 90)
        XCTAssertEqual(playback.currentTime, 1, accuracy: 0.001)
        playback.seek(to: -90)
        XCTAssertEqual(playback.currentTime, 0, accuracy: 0.001)
        playback.togglePlayback(recordingId: id, fileURL: url, trimRange: AudioTrimRange(startSeconds: 1, endSeconds: 3))
        XCTAssertEqual(playback.duration, 2, accuracy: 0.001)
    }
}
