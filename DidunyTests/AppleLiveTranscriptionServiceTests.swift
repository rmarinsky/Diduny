import AVFoundation
@testable import Diduny
import XCTest

final class AppleLiveTranscriptionServiceTests: XCTestCase {
    private let pcm16k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    func testPCM16DataBecomesSameFormatBuffer() throws {
        let samples: [Int16] = [0, 1000, -1000, 32767]
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let buffer = try XCTUnwrap(AppleLiveTranscriptionService.buffer(from: data, format: pcm16k))
        XCTAssertEqual(buffer.frameLength, 4)
        XCTAssertEqual(buffer.int16ChannelData?[0][3], 32767)
    }

    func testConvertsToAnotherEngineFormat() throws {
        let float48k = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let data = Data(count: 1600 * 2) // 100 ms of silence
        let buffer = try XCTUnwrap(AppleLiveTranscriptionService.buffer(from: data, format: float48k))
        XCTAssertEqual(buffer.format.sampleRate, 48000)
        XCTAssertGreaterThan(buffer.frameLength, 4000)
    }

    func testEmptyDataGivesNoBuffer() {
        XCTAssertNil(AppleLiveTranscriptionService.buffer(from: Data(), format: pcm16k))
    }
}
