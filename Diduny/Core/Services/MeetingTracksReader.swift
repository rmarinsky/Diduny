import AVFoundation
import Foundation

/// Reads a meeting's 2-channel file (`MeetingTracksWriter`) in blocks, so a long meeting is never
/// held in memory: per-10 ms energy of each channel, and optionally each channel as its own mono file
/// for voice detection.
enum MeetingTracksReader {
    struct Envelope: Equatable {
        static let framesPerSecond: Double = 100

        var framesPerSecond: Double = Self.framesPerSecond
        /// Sum of squared samples per frame.
        var mic: [Float] = []
        var system: [Float] = []

        var micTotal: Float { mic.reduce(0, +) }
        var systemTotal: Float { system.reduce(0, +) }
    }

    struct Output {
        let envelope: Envelope
        /// Mono 16 kHz files, when `channelFilesDirectory` was given.
        let micURL: URL?
        let systemURL: URL?
    }

    enum ReaderError: LocalizedError {
        case notTwoChannels

        var errorDescription: String? {
            String(localized: "The meeting tracks file doesn't have two channels.")
        }
    }

    /// `range` limits reading to a trimmed part of the recording (seconds from the start).
    static func read(_ url: URL, range: AudioTrimRange?, channelFilesDirectory: URL?) throws -> Output {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount == 2 else { throw ReaderError.notTwoChannels }
        let sampleRate = format.sampleRate

        var startFrame: AVAudioFramePosition = 0
        var endFrame = file.length
        if let range {
            startFrame = min(file.length, AVAudioFramePosition(range.startSeconds * sampleRate))
            endFrame = min(file.length, AVAudioFramePosition(range.endSeconds * sampleRate))
        }
        file.framePosition = startFrame

        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let monoSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let micURL = channelFilesDirectory?.appendingPathComponent("tracks-mic.wav")
        let systemURL = channelFilesDirectory?.appendingPathComponent("tracks-system.wav")
        var micFile = try micURL.map { try AVAudioFile(forWriting: $0, settings: monoSettings) }
        var systemFile = try systemURL.map { try AVAudioFile(forWriting: $0, settings: monoSettings) }
        defer {
            micFile = nil
            systemFile = nil
        }

        let samplesPerFrame = max(1, Int(sampleRate / Envelope.framesPerSecond))
        let blockFrames = AVAudioFrameCount(samplesPerFrame * 100)
        guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            return Output(envelope: Envelope(), micURL: nil, systemURL: nil)
        }

        var envelope = Envelope()
        var position = startFrame
        while position < endFrame {
            let toRead = AVAudioFrameCount(min(AVAudioFramePosition(blockFrames), endFrame - position))
            try file.read(into: block, frameCount: toRead)
            let count = Int(block.frameLength)
            guard count > 0, let channels = block.floatChannelData else { break }
            position += AVAudioFramePosition(count)

            for (samples, isMic) in [(channels[0], true), (channels[1], false)] {
                var frameStart = 0
                while frameStart < count {
                    let frameEnd = min(count, frameStart + samplesPerFrame)
                    var energy: Float = 0
                    for i in frameStart ..< frameEnd {
                        energy += samples[i] * samples[i]
                    }
                    if isMic { envelope.mic.append(energy) } else { envelope.system.append(energy) }
                    frameStart = frameEnd
                }
                if let output = isMic ? micFile : systemFile,
                   let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(count))
                {
                    mono.frameLength = AVAudioFrameCount(count)
                    mono.floatChannelData![0].update(from: samples, count: count)
                    try output.write(from: mono)
                }
            }
        }

        return Output(envelope: envelope, micURL: micURL, systemURL: systemURL)
    }
}
