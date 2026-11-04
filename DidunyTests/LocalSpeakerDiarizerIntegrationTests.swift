import AVFoundation
@testable import Diduny
import XCTest

/// Runs the real FluidAudio diarizer (downloads ~22 MB of models on first run), so it is opt-in:
/// `TEST_RUNNER_DIDUNY_DIARIZER_TEST=1 xcodebuild test -only-testing:DidunyTests/LocalSpeakerDiarizerIntegrationTests`.
/// Two synthetic voices from `say` stand in for two people.
final class LocalSpeakerDiarizerIntegrationTests: XCTestCase {
    private let lines = [
        ("Fred", "Good morning everyone, let's start with the roadmap for this quarter and the main risks."),
        ("Karen", "Sure. Last week we shipped the import fix, and the support queue is finally shorter."),
        ("Fred", "Great. What is still blocking the release of the new billing screen for our customers?"),
        ("Karen", "Mostly the translations and one crash on older Macs that we are still investigating today."),
        ("Fred", "Okay, then let's give that crash priority and move the translations to next week."),
        ("Karen", "Agreed. I will write a short summary and send it to the whole team after this call."),
    ]

    func test_diarizerSeparatesTwoVoicesAndEnrolledVoiceMatches() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DIDUNY_DIARIZER_TEST"] == "1", "Opt-in: downloads models")
        try XCTSkipUnless(LocalSpeakerDiarizer.isSupported, "Needs Apple silicon and macOS 15+")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        var conversation: [Float] = []
        var fredSpans: [Range<TimeInterval>] = []
        var fredOnly: [Float] = []
        let pause = [Float](repeating: 0, count: 8000)
        for (index, (voice, text)) in lines.enumerated() {
            let samples = try speak(text, voice: voice, to: directory.appendingPathComponent("\(index).wav"))
            let start = Double(conversation.count) / 16000
            conversation += samples + pause
            if voice == "Fred" {
                fredSpans.append(start ..< start + Double(samples.count) / 16000)
                fredOnly += samples
            }
        }
        let conversationURL = directory.appendingPathComponent("conversation.wav")
        try write(conversation, to: conversationURL)

        let diarization = try await LocalSpeakerDiarizer.shared.diarize(fileURL: conversationURL)
        let speakers = Set(diarization.turns.map(\.speakerId))
        XCTAssertGreaterThanOrEqual(speakers.count, 2, "turns: \(diarization.turns)")

        // Fred's lines should mostly belong to one speaker.
        var fredTime: [String: TimeInterval] = [:]
        for turn in diarization.turns {
            for span in fredSpans {
                let shared = min(span.upperBound, turn.end) - max(span.lowerBound, turn.start)
                if shared > 0 { fredTime[turn.speakerId, default: 0] += shared }
            }
        }
        let fredId = try XCTUnwrap(fredTime.max { $0.value < $1.value }?.key)

        // Enrollment from Fred's voice alone points at the same speaker.
        let embedding = try await LocalSpeakerDiarizer.shared.dominantVoiceEmbedding(samples: fredOnly)
        let profile = try XCTUnwrap(embedding)
        XCTAssertEqual(SpeakerLabeling.matchingSpeaker(profile, in: diarization.embeddings), fredId)
    }

    private func speak(_ text: String, voice: String, to url: URL) throws -> [Float] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, "--data-format=LEF32@16000", text]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func write(_ samples: [Float], to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData![0].update(from: samples, count: samples.count)
        try file.write(from: buffer)
    }
}
