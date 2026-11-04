import AVFoundation
import Foundation
import Testing

@testable import Diduny

/// Voice notes are written through `Mono16kConverter` the same way `AudioRecorderService` does it:
/// mic-sized tap buffers in the native format, converted one by one into a 16 kHz mono Int16 WAV.
@Suite("Mono16kConverter voice-note file format")
struct Mono16kConverterTests {
    @Test("48 kHz stereo Float32 tap buffers become a 16 kHz mono Int16 WAV of the same duration")
    func convertsNativeMicFormatTo16kMono() throws {
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let converter = try #require(Mono16kConverter(inputFormat: inputFormat))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let seconds = 3.0
        let totalFrames = Int(inputFormat.sampleRate * seconds)
        let tapFrames = 4096
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: Mono16kConverter.outputFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            var written = 0
            while written < totalFrames {
                let frames = min(tapFrames, totalFrames - written)
                let buffer = try #require(sineBuffer(format: inputFormat, frames: frames, offset: written))
                if let converted = converter.convert(buffer) {
                    try file.write(from: converted)
                }
                written += frames
            }
        }

        let file = try AVAudioFile(forReading: url)
        let streamDescription = file.fileFormat.streamDescription.pointee
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(streamDescription.mBitsPerChannel == 16)
        #expect(streamDescription.mFormatFlags & kAudioFormatFlagIsFloat == 0)

        // Resampler latency may hold back a few milliseconds at the end.
        let duration = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(duration - seconds) < 0.02)
    }

    private func sineBuffer(format: AVAudioFormat, frames: Int, offset: Int) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0 ..< Int(format.channelCount) {
            for frame in 0 ..< frames {
                let t = Double(offset + frame) / format.sampleRate
                channels[channel][frame] = Float(0.5 * sin(2 * .pi * 440 * t))
            }
        }
        return buffer
    }
}
