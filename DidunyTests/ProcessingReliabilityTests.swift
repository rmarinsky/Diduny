import Foundation
import Testing
@testable import Diduny

/// Stage 1 reliability fixes for the transcription queue, Whisper, storage and quitting.
@MainActor
@Suite(.serialized)
struct ProcessingReliabilityTests {
    private final class Calls { var whisper = 0 }

    /// Holds a fake engine until the test lets it finish, like Whisper ignoring cancellation.
    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async { await withCheckedContinuation { waiters.append($0) } }
        func openAll() { let all = waiters; waiters = []; all.forEach { $0.resume() } }
        func openFirst() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
    }

    private struct EchoTranslator: TextTranslationProtocol {
        func translate(text: String, sourceLanguage _: String, targetLanguage _: String) async throws -> String { text }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProcessingReliability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func storage(_ directory: URL) throws -> RecordingsLibraryStorage {
        RecordingsLibraryStorage(baseDirectory: directory, batchStorage: try TranscriptionBatchStorage(baseDirectory: directory))
    }

    private func save(_ storage: RecordingsLibraryStorage) throws -> UUID {
        try #require(storage.saveRecording(audioData: Data("RIFF....WAVEfmt ".utf8), type: .meeting, duration: 42, forceSave: true))
    }

    private func runner(_ calls: Calls, whisper: @escaping () async throws -> String = { "whisper text" }) -> QueueEngineRunner {
        QueueEngineRunner(
            cloud: { _ in GeneratedTranscript(text: "cloud text") },
            whisper: { calls.whisper += 1; return try await GeneratedTranscript(text: whisper()) },
            whisperTranslateToEnglish: { "" },
            onDevice: { _ in "device text" },
            elevenLabs: { _ in GeneratedTranscript(text: "el text") },
            translator: EchoTranslator()
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Fix 5: the Mac stays awake while the queue works

    @Test func queueHoldsAnActivityWhileItWorks() async throws {
        let storage = try storage(try directory())
        let id = try save(storage)
        var begun = 0, ended = 0
        let activity = ProcessingActivity(begin: { _ in begun += 1; return NSObject() }, end: { _ in ended += 1 })
        let queue = RecordingQueueService(storage: storage, localModelIsAvailable: { _ in true }, hasSession: { true },
                                          makeRunner: { _ in runner(Calls()) }, activity: activity)
        #expect(queue.enqueue([id], action: .transcribe, engineOverride: .whisper, speakerLabels: false))
        await waitUntil { !queue.isProcessing && ended == 1 }
        #expect(begun == 1)
        #expect(ended == 1)
        #expect(ProcessingActivity.options.contains(.idleSystemSleepDisabled))
    }

    // MARK: - Fix 6: Whisper stops on cancel, and a cancelled run leaves a re-queued recording alone

    @Test func abortFlagReachesTheWhisperCallback() {
        let flag = WhisperContext.AbortFlag()
        let pointer = Unmanaged.passUnretained(flag).toOpaque()
        #expect(!WhisperContext.AbortFlag.isAborted(pointer))
        flag.abort()
        #expect(WhisperContext.AbortFlag.isAborted(pointer))
        #expect(!WhisperContext.AbortFlag.isAborted(nil))
    }

    @Test func cancelledRunDoesNotOverwriteTheRecordingQueuedAgain() async throws {
        let storage = try storage(try directory())
        let id = try save(storage)
        let calls = Calls()
        let gate = Gate()
        var returned = 0
        let queue = RecordingQueueService(storage: storage, localModelIsAvailable: { _ in true }, hasSession: { true },
                                          makeRunner: { _ in runner(calls, whisper: { await gate.wait(); returned += 1; return "late" }) })
        #expect(queue.enqueue([id], action: .transcribe, engineOverride: .whisper, speakerLabels: false))
        await waitUntil { calls.whisper == 1 }

        queue.cancelAll()
        #expect(queue.enqueue([id], action: .transcribe, engineOverride: .whisper, speakerLabels: false))
        await waitUntil { calls.whisper == 2 }
        gate.openFirst() // The cancelled run finishes only now, while the new run is still working.
        await waitUntil { returned == 1 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(storage.recordings.first { $0.id == id }?.status == .processing)
        #expect(queue.isRunning(id))
        gate.openAll()
        await waitUntil { !queue.isProcessing }
        #expect(storage.recordings.first { $0.id == id }?.status == .transcribed)
    }

    // MARK: - Fix 7: what the queue works on survives quitting

    @Test func interruptedItemIsQueuedAgainAtTheNextLaunch() throws {
        let folder = try directory()
        let first = try storage(folder)
        let id = try save(first)
        let before = RecordingQueueService(storage: first, startsAutomatically: false, localModelIsAvailable: { _ in true },
                                           hasSession: { true })
        #expect(before.enqueue([id], action: .transcribeDiarize, providerOverride: .local, speakerLabels: false))
        #expect(before.journalEntryForTesting(id)?.action == .transcribeDiarize)

        // Next launch: the library resets the interrupted row, the journal brings it back.
        let next = try storage(folder)
        #expect(next.recordings.first { $0.id == id }?.status == .unprocessed)
        let after = RecordingQueueService(storage: next, startsAutomatically: false, localModelIsAvailable: { _ in true },
                                          hasSession: { true })
        after.resumeInterrupted()
        #expect(after.isQueued(id))
        #expect(after.journalEntryForTesting(id)?.providerOverride == TranscriptionProvider.local.rawValue)
    }

    @Test func journalKeepsTheCloudJobAndDropsFinishedItems() async throws {
        let folder = try directory()
        let journal = QueueJournal(directory: folder)
        let id = UUID()
        journal.save([.init(recordingID: id, action: .transcribe, cloudJobID: "job-1")])
        #expect(journal.load().first?.cloudJobID == "job-1")

        let storage = try storage(folder)
        let done = try save(storage)
        let queue = RecordingQueueService(storage: storage, localModelIsAvailable: { _ in true }, hasSession: { true },
                                          makeRunner: { _ in runner(Calls()) })
        #expect(queue.enqueue([done], action: .transcribe, engineOverride: .whisper, speakerLabels: false))
        await waitUntil { !queue.isProcessing }
        #expect(storage.recordings.first { $0.id == done }?.status == .transcribed)
        #expect(queue.journalEntryForTesting(done) == nil)
        #expect(!journal.load().contains { $0.recordingID == done })
    }

    // MARK: - Fix 10: one loaded Whisper model for every service

    @Test func sharedRegistryLoadsOncePerKeyAndFreesUnusedValues() async throws {
        final class Model: @unchecked Sendable {}
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func next() { lock.withLock { count += 1 } }
        }
        let registry = SharedLoadRegistry<Model>()
        let loads = Counter()
        let load: @Sendable () throws -> Model = { loads.next(); Thread.sleep(forTimeInterval: 0.05); return Model() }

        async let a = registry.value(for: "large-v3", load: load)
        async let b = registry.value(for: "large-v3", load: load)
        let (first, second) = try await (a, b)
        #expect(first === second)
        #expect(loads.count == 1)
        _ = try await registry.value(for: "large-v3", load: load)
        #expect(loads.count == 1)

        weak var released: Model?
        do {
            var held: Model? = try await registry.value(for: "small", load: load)
            released = held
            held = nil
            _ = held
        }
        #expect(released == nil)
        _ = try await registry.value(for: "small", load: load)
        #expect(loads.count == 3)
    }

    // MARK: - Fix 11: a new queue does not reset rows another queue is processing

    @Test func creatingAQueueLeavesProcessingRowsAlone() throws {
        let storage = try storage(try directory())
        let id = try save(storage)
        storage.updateRecording(id: id, status: .processing, error: nil)
        _ = RecordingQueueService(storage: storage, startsAutomatically: false, hasSession: { true })
        #expect(storage.recordings.first { $0.id == id }?.status == .processing)
    }

    // MARK: - Fix 12: quitting, a second copy, leftovers

    @Test func flushWritesQueuedMetadataToDisk() throws {
        let folder = try directory()
        let storage = try storage(folder)
        let id = try save(storage)
        storage.updateRecording(id: id, status: .failed, error: "boom")
        storage.flushPendingWrites()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode([Recording].self,
                                        from: Data(contentsOf: folder.appendingPathComponent("recordings_metadata.json")))
        #expect(onDisk.first { $0.id == id }?.status == .failed)
    }

    @Test func secondInstanceCannotTakeTheLock() throws {
        let folder = try directory()
        var first: AppInstanceLock?
        if case let .acquired(lock) = AppInstanceLock.acquire(in: folder) { first = lock }
        #expect(first != nil)
        guard case .heldElsewhere = AppInstanceLock.acquire(in: folder) else { Issue.record("second copy got the lock"); return }
        first = nil
        guard case .acquired = AppInstanceLock.acquire(in: folder) else { Issue.record("lock not released"); return }
        // A folder the lock file cannot be created in reports that, never a lock it does not hold.
        guard case .unavailable = AppInstanceLock.acquire(in: URL(fileURLWithPath: "/dev/null/nope")) else {
            Issue.record("expected unavailable"); return
        }
    }

    @Test func leftoverInProgressFolderOfAFinishedRecordingIsRemoved() async throws {
        let folder = try directory()
        let storage = try storage(folder)
        let id = try save(storage)
        let store = try InProgressRecordingStore(baseDirectory: folder.appendingPathComponent("InProgressRecordings"))
        _ = try await store.directoryURL(for: id)

        let promoted = await AppDelegate().promoteOrphanedInProgressMeetings(store: store, storage: storage)

        #expect(!promoted.contains(id))
        #expect(try await !store.allInProgressRecordingIDs().contains(id))
        #expect(storage.recordings.first { $0.id == id }?.status != .needsRecovery)
    }

    @Test func deletionRecoveryWithLostFilesStillLoadsTheLibrary() throws {
        let folder = try directory()
        let first = try storage(folder)
        let kept = try save(first)
        let lost = try save(first)
        let lostRecording = try #require(first.recordings.first { $0.id == lost })
        let lostPath = first.audioFileURL(for: lostRecording).path
        try FileManager.default.removeItem(atPath: lostPath)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RecordingDeletionRecovery(
            recordings: first.recordings,
            stagedFiles: [RecordingDeletionStagedFile(originalPath: lostPath, stagedPath: folder.appendingPathComponent("gone").path)]
        )).write(to: folder.appendingPathComponent("recordings_delete_recovery.json"))

        let next = try storage(folder)

        #expect(next.hasLoadedLibrary)
        #expect(next.recordings.map(\.id) == [kept])
    }

    @Test func quittingStopsRunningNotesTools() async throws {
        let task = Task { try await CLIRunner.run("/bin/sleep", ["30"], stdin: nil, in: nil, environment: [:]) }
        await waitUntil { CLIRunner.runningCount == 1 }
        CLIRunner.terminateAll()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(CLIRunner.runningCount == 0)
    }

    /// The old run of a recording, cancelled and replaced, ends after the new run finished: the
    /// finished transcript stays.
    @Test func cancelledRunEndingAfterTheNewRunLeavesItsResult() async throws {
        let storage = try storage(try directory())
        let id = try save(storage)
        let calls = Calls()
        let oldGate = Gate()
        let queue = RecordingQueueService(storage: storage, localModelIsAvailable: { _ in true }, hasSession: { true },
                                          makeRunner: { _ in runner(calls, whisper: {
                                              if calls.whisper == 1 { await oldGate.wait() }
                                              return "text"
                                          }) })
        #expect(queue.enqueue([id], action: .transcribe, engineOverride: .whisper, speakerLabels: false))
        await waitUntil { calls.whisper == 1 }
        queue.cancelAll()
        #expect(queue.enqueue([id], action: .transcribe, engineOverride: .whisper, speakerLabels: false))
        await waitUntil { storage.recordings.first { $0.id == id }?.status == .transcribed }
        oldGate.openAll()
        try await Task.sleep(for: .milliseconds(100))
        #expect(storage.recordings.first { $0.id == id }?.status == .transcribed)
    }

    /// A file that is still in the staging folder keeps the deletion recovery pending, so it is not deleted.
    @Test func deletionRecoveryWaitsForFilesStillStaged() throws {
        let folder = try directory()
        let first = try storage(folder)
        let id = try save(first)
        let recording = try #require(first.recordings.first { $0.id == id })
        let original = first.audioFileURL(for: recording)
        let staged = folder.appendingPathComponent("staged-audio")
        try FileManager.default.moveItem(at: original, to: staged)
        // Its original folder is gone, so moving it back fails and the file stays staged.
        let unreachable = folder.appendingPathComponent("gone-folder/audio.m4a")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RecordingDeletionRecovery(
            recordings: first.recordings,
            stagedFiles: [RecordingDeletionStagedFile(originalPath: unreachable.path, stagedPath: staged.path)]
        )).write(to: folder.appendingPathComponent("recordings_delete_recovery.json"))

        let next = try storage(folder)

        #expect(!next.hasLoadedLibrary)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recordings_delete_recovery.json").path))
    }
}
