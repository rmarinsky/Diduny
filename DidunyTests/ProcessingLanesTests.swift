import Foundation
import Testing
@testable import Diduny

/// Stage 2: cloud work does not wait behind Whisper, and the board shows what each recording is doing.
@MainActor
@Suite(.serialized)
struct ProcessingLanesTests {
    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async { await withCheckedContinuation { waiters.append($0) } }
        func openAll() { let all = waiters; waiters = []; all.forEach { $0.resume() } }
    }

    private struct EchoTranslator: TextTranslationProtocol {
        func translate(text: String, sourceLanguage _: String, targetLanguage _: String) async throws -> String { text }
    }

    private func storage() throws -> RecordingsLibraryStorage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProcessingLanes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return RecordingsLibraryStorage(baseDirectory: url, batchStorage: try TranscriptionBatchStorage(baseDirectory: url))
    }

    private func save(_ storage: RecordingsLibraryStorage) throws -> UUID {
        try #require(storage.saveRecording(audioData: Data("RIFF....WAVEfmt ".utf8), type: .meeting, duration: 42, forceSave: true))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func onThisMacTakesOneRecordingCloudSeveral() {
        #expect(RecordingQueueService.laneHasRoom(.onThisMac, running: []))
        #expect(!RecordingQueueService.laneHasRoom(.onThisMac, running: [.onThisMac]))
        #expect(RecordingQueueService.laneHasRoom(.onThisMac, running: [.cloud, .cloud, .cloud]))
        #expect(RecordingQueueService.laneHasRoom(.cloud, running: [.onThisMac, .cloud, .cloud]))
        #expect(!RecordingQueueService.laneHasRoom(.cloud, running: Array(repeating: .cloud, count: RecordingQueueService.cloudLaneLimit)))
    }

    @Test func cloudRecordingFinishesWhileWhisperWorksAndTheBoardShowsBoth() async throws {
        let storage = try storage()
        let local = try save(storage)
        let cloud = try save(storage)
        let localWaiting = try save(storage)
        let gate = Gate()
        var whisperCalls = 0
        let board = ProcessingBoard()
        let runner = QueueEngineRunner(
            cloud: { _ in GeneratedTranscript(text: "cloud text") },
            whisper: { whisperCalls += 1; await gate.wait(); return GeneratedTranscript(text: "whisper text") },
            whisperTranslateToEnglish: { "" },
            onDevice: { _ in "" },
            elevenLabs: { _ in GeneratedTranscript(text: "") },
            translator: EchoTranslator()
        )
        let queue = RecordingQueueService(storage: storage, localModelIsAvailable: { _ in true }, hasSession: { true },
                                          makeRunner: { _ in runner }, board: board)

        #expect(queue.enqueue([local, localWaiting], action: .transcribe, engineOverride: .whisper, speakerLabels: false))
        await waitUntil { whisperCalls == 1 }
        #expect(board.work(for: local)?.lane == .onThisMac)
        #expect(board.work(for: local)?.kind == .transcription)
        #expect(board.work(for: localWaiting) == nil, "a second Whisper item waits for the first")

        #expect(queue.enqueue([cloud], action: .transcribe, engineOverride: .didunyCloud))
        await waitUntil { storage.recordings.first { $0.id == cloud }?.status == .transcribed }
        #expect(storage.recordings.first { $0.id == cloud }?.status == .transcribed)
        #expect(queue.isRunning(local))
        #expect(board.work(for: cloud) == nil)

        gate.openAll()
        await waitUntil { whisperCalls == 2 }
        gate.openAll()
        await waitUntil { !queue.isProcessing }
        #expect(storage.recordings.filter { $0.status == .transcribed }.count == 3)
        #expect(board.isEmpty)
    }

    @Test func boardEndsOnlyTheKindThatFinished() {
        let board = ProcessingBoard()
        let id = UUID()
        board.start(id, kind: .transcription, lane: .cloud)
        board.finish(id, kind: .notes)
        #expect(board.work(for: id)?.kind == .transcription)
        // Notes and a new transcription of one recording are both shown.
        board.start(id, kind: .notes, lane: .notes)
        board.update(id, notes: .checking)
        #expect(board.ordered.count == 2)
        board.finish(id, kind: .transcription)
        #expect(board.work(for: id, kind: .notes)?.notes == .checking)
        #expect(board.work(for: id, kind: .transcription) == nil)
        board.finish(id, kind: .notes)
        #expect(board.isEmpty)
    }

    @Test func completedTranscriptionAnnouncesItselfForNotes() throws {
        let storage = try storage()
        let id = try save(storage)
        var announced: UUID?
        let observer = NotificationCenter.default.addObserver(forName: .recordingTranscriptCompleted, object: storage, queue: nil) {
            announced = $0.userInfo?["id"] as? UUID
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        storage.completeTranscription(id: id, status: .transcribed, text: "done", segments: nil, kind: .cloud)
        #expect(announced == id)
    }
}
