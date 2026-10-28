import AVFoundation
@testable import Diduny
import XCTest

final class SpeakerLabelsTests: XCTestCase {
    private typealias Turn = SpeakerLabeling.Turn
    private typealias Diarization = SpeakerLabeling.Diarization

    private func segment(_ start: Double, _ end: Double, _ text: String = "text") -> TimedTranscriptSegment {
        TimedTranscriptSegment(startMilliseconds: Int(start * 1000), endMilliseconds: Int(end * 1000), text: text)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - A: louder channel

    func test_sides_pickLouderChannelAndKeepPreviousOnTie() {
        // 100 frames per second: mic loud for 0–2 s, system loud for 2–4 s, silence for 4–5 s.
        let envelope = MeetingTracksReader.Envelope(
            mic: Array(repeating: 1, count: 200) + Array(repeating: 0, count: 300),
            system: Array(repeating: 0, count: 200) + Array(repeating: 1, count: 200) + Array(repeating: 0, count: 100)
        )
        let segments = [segment(0, 2), segment(2, 4), segment(4, 5)]

        XCTAssertEqual(
            SpeakerLabeling.sides(for: segments, envelope: envelope),
            [.microphone, .system, .system]
        )
    }

    func test_labelByTracks_withoutVoiceDetection_isMeAndOthers() {
        let labelled = SpeakerLabeling.labelByTracks(
            [segment(0, 1), segment(1, 2)],
            sides: [.microphone, .system],
            mic: nil,
            system: nil,
            voiceProfile: nil
        )
        XCTAssertEqual(labelled.map(\.speaker), ["Me", "Others"])
    }

    // MARK: - B: voice detection per channel

    func test_labelByTracks_dominantMicVoiceIsMe_othersNumberedByFirstAppearance() {
        let mic = Diarization(
            turns: [Turn(speakerId: "S1", start: 0, end: 10), Turn(speakerId: "S2", start: 20, end: 22)],
            embeddings: [:]
        )
        let system = Diarization(turns: [Turn(speakerId: "S1", start: 10, end: 20)], embeddings: [:])
        let labelled = SpeakerLabeling.labelByTracks(
            [segment(0, 5), segment(11, 15), segment(20, 22), segment(16, 19)],
            sides: [.microphone, .system, .microphone, .system],
            mic: mic,
            system: system,
            voiceProfile: nil
        )
        XCTAssertEqual(
            labelled.map(\.speaker),
            ["Me", "Speaker 2 (remote)", "Speaker 3 (room)", "Speaker 2 (remote)"]
        )
    }

    func test_labelByTracks_channelWithoutOverlap_fallsBackToMeOrOthers() {
        let system = Diarization(turns: [Turn(speakerId: "S1", start: 50, end: 60)], embeddings: [:])
        let labelled = SpeakerLabeling.labelByTracks(
            [segment(0, 1)],
            sides: [.system],
            mic: nil,
            system: system,
            voiceProfile: nil
        )
        XCTAssertEqual(labelled.map(\.speaker), ["Others"])
    }

    func test_enrolledVoice_overridesDominantMicSpeaker() {
        let mic = Diarization(
            turns: [Turn(speakerId: "S1", start: 0, end: 30), Turn(speakerId: "S2", start: 30, end: 35)],
            embeddings: ["S1": [1, 0, 0], "S2": [0, 1, 0]]
        )
        XCTAssertEqual(SpeakerLabeling.meSpeakerId(in: mic, voiceProfile: nil), "S1")
        XCTAssertEqual(SpeakerLabeling.meSpeakerId(in: mic, voiceProfile: [0, 0.98, 0.1]), "S2")
    }

    func test_voiceMatch_needsDistanceUnderThresholdAndClearGap() {
        // Too far from everyone.
        XCTAssertNil(SpeakerLabeling.matchingSpeaker([1, 0], in: ["S1": [0, 1]]))
        // Two speakers equally close: ambiguous.
        XCTAssertNil(SpeakerLabeling.matchingSpeaker([1, 0], in: ["S1": [1, 0.05], "S2": [1, -0.05]]))
        // One clear match.
        XCTAssertEqual(SpeakerLabeling.matchingSpeaker([1, 0], in: ["S1": [1, 0.05], "S2": [0, 1]]), "S1")
    }

    func test_labelByVoice_plainSpeakerNumbersFromOne() {
        let diarization = Diarization(
            turns: [Turn(speakerId: "S2", start: 0, end: 5), Turn(speakerId: "S1", start: 5, end: 10)],
            embeddings: [:]
        )
        let labelled = SpeakerLabeling.labelByVoice([segment(0, 4), segment(6, 9), segment(1, 2)], diarization: diarization)
        XCTAssertEqual(labelled.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    // MARK: - Transcript text

    func test_format_groupsSameSpeakerWithinGapLikeCloud() {
        let segments = [
            segment(4, 6, "Let's start").withSpeaker("Me"),
            segment(7, 8, "with the roadmap.").withSpeaker("Me"),
            segment(9, 12, "Sure.").withSpeaker("Speaker 2 (remote)"),
            segment(20, 21, "Next?").withSpeaker("Speaker 2 (remote)"),
        ]
        XCTAssertEqual(
            DiarizedTranscriptFormatter.format(labelledSegments: segments),
            """
            [00:04] Me: Let's start with the roadmap.

            [00:09] Speaker 2 (remote): Sure.

            [00:20] Speaker 2 (remote): Next?
            """
        )
    }

    // MARK: - 2-channel file

    func test_tracksFile_roundTripsChannelsAndRespectsTrim() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("tracks.wav")
        let writer = try MeetingTracksWriter(url: url)
        let second = 16000
        writer.append(mic: Array(repeating: 0.5, count: second), system: []) // 0–1 s: mic only
        writer.append(mic: [], system: Array(repeating: 0.5, count: second)) // 1–2 s: system only
        writer.close()

        let whole = try MeetingTracksReader.read(url, range: nil, channelFilesDirectory: directory)
        XCTAssertEqual(whole.envelope.mic.count, 200)
        XCTAssertGreaterThan(whole.envelope.mic[50], 0)
        XCTAssertEqual(whole.envelope.mic[150], 0)
        XCTAssertEqual(whole.envelope.system[50], 0)
        XCTAssertGreaterThan(whole.envelope.system[150], 0)

        let micFile = try AVAudioFile(forReading: XCTUnwrap(whole.micURL))
        XCTAssertEqual(micFile.fileFormat.channelCount, 1)
        XCTAssertEqual(micFile.length, AVAudioFramePosition(2 * second))

        let trimmed = try MeetingTracksReader.read(
            url,
            range: AudioTrimRange(startSeconds: 1, endSeconds: 2),
            channelFilesDirectory: nil
        )
        XCTAssertEqual(trimmed.envelope.mic.count, 100)
        XCTAssertEqual(trimmed.envelope.micTotal, 0)
        XCTAssertGreaterThan(trimmed.envelope.systemTotal, 0)
    }

    func test_tracksFile_headerIsRepairedWhenNeverClosed() throws {
        let url = try temporaryDirectory().appendingPathComponent("tracks.wav")
        var writer: MeetingTracksWriter? = try MeetingTracksWriter(url: url)
        writer?.append(mic: Array(repeating: 0.1, count: 1600), system: [])
        writer = nil // crash: size fields still say 0

        XCTAssertTrue(MeetingTracksWriter.repairHeader(at: url))
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.length, 1600)
    }

    @MainActor
    func test_library_keepsTracksAndDeletesThemWithTheRecording() async throws {
        let directory = try temporaryDirectory()
        let store = RecordingsLibraryStorage(baseDirectory: directory, audioCompressor: { $0 })
        let id = try XCTUnwrap(store.saveRecording(audioData: Data([1]), type: .meeting, duration: 2, forceSave: true))
        let wav = directory.appendingPathComponent("tracks.wav")
        let writer = try MeetingTracksWriter(url: wav)
        writer.append(mic: [0.1, 0.2], system: [0.3, 0.4])
        writer.close()

        await store.attachTracks(from: wav, to: id)
        let tracks = try XCTUnwrap(store.tracksFileURL(for: id))
        XCTAssertEqual(tracks.lastPathComponent, "\(id.uuidString).tracks.wav")

        XCTAssertTrue(store.deleteRecordings([id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tracks.path))
    }

    // MARK: - Enrollment and settings

    func test_voiceProfile_savesLoadsAndDeletes() throws {
        let store = try VoiceProfileStore(directory: temporaryDirectory())
        XCTAssertNil(store.load())
        try store.save(embedding: [0.6, 0.8], at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(store.load(), VoiceProfileStore.Profile(embedding: [0.6, 0.8], savedAt: Date(timeIntervalSince1970: 0)))
        try store.delete()
        XCTAssertNil(store.load())
    }

    func test_enrollmentSpeechSeconds_countsOnlyLoudWindows() {
        let loud = Array(repeating: Float(0.1), count: 16000 * 9)
        let quiet = Array(repeating: Float(0.001), count: 16000 * 5)
        XCTAssertEqual(VoiceEnrollmentRecorder.speechSeconds(in: loud + quiet), 9, accuracy: 0.1)
    }

    func test_identifyingSpeakersStage_sitsBetweenTranscribingAndFinishing() {
        let stage = QueueProgress.Stage.identifyingSpeakers
        XCTAssertGreaterThan(stage.order, QueueProgress.Stage.transcribing.order)
        XCTAssertLessThan(stage.order, QueueProgress.Stage.finishing.order)
        let progress = QueueProgress(stage: stage, provider: .local, totalSeconds: 600)
        XCTAssertEqual(QueueProgressFormatter.rowLine(progress), "Identifying speakers")
        XCTAssertNil(QueueProgressFormatter.barFraction(progress))
        XCTAssertNil(QueueProgressFormatter.timeLeft(progress))
    }
}
