import AVFoundation
@testable import Diduny
import Foundation
import Testing

struct AudioConverterDownmixTests {
    /// A 48 kHz 2-channel WAV with a tone on `toneChannel` and silence on the other.
    private func stereoWAV(toneChannel: Int) throws -> Data {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let frames: AVAudioFrameCount = 48000
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        for i in 0..<Int(frames) {
            channels[toneChannel][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / 48000)
            channels[1 - toneChannel][i] = 0
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("downmix-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    private func rms(_ samples: [Float]) -> Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
    }

    @Test(arguments: [0, 1])
    func monoOutputKeepsEachChannel(toneChannel: Int) throws {
        let samples = try AudioConverter.convertToWhisperFormat(audioData: stereoWAV(toneChannel: toneChannel))
        #expect(rms(samples) > 0.05, "channel \(toneChannel) was dropped")
    }
}
