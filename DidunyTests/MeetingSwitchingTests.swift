@testable import Diduny
import Foundation
import Testing

/// ADR-0013 D8: the switching rules, without audio, sockets or a clock.
struct MeetingSwitchMachineTests {
    private static let cloud = MeetingEngineTarget.live(.didunyCloud)
    private static let local = MeetingEngineTarget.live(.whisper)
    private static let record = MeetingEngineTarget.afterStopOnly(.parakeet)

    private func machine(_ start: MeetingEngineTarget = Self.cloud) -> MeetingSwitchMachine {
        MeetingSwitchMachine(start: start, afterStopEngine: .parakeet)
    }

    private func at(_ elapsed: Double, turns: Int = 1) -> MeetingCutPoint {
        MeetingCutPoint(frame: Int(elapsed * 16000), elapsed: elapsed, turns: turns)
    }

    @Test("A live click highlights at once, connects, and cuts only when ready")
    func liveClick() {
        var m = machine(Self.local)
        let effects = m.handle(.click(Self.cloud, failure: nil, at: at(6)))
        #expect(effects == [.startSession(id: 2, target: Self.cloud)])
        #expect(m.selected == Self.cloud)
        #expect(m.running == Self.local)
        #expect(m.isConnecting)
        #expect(m.history.spans.count == 1)
        #expect(m.handle(.sessionReady(id: 2, at: at(8))) == [.cutTo(id: 2)])
        #expect(m.running == Self.cloud)
        #expect(!m.isConnecting)
        #expect(m.history.spans.map(\.startFrame) == [0, 8 * 16000])
    }

    @Test("Record only cuts now and stops the current engine")
    func recordOnlyCutsNow() {
        var m = machine()
        #expect(m.handle(.click(Self.record, failure: nil, at: at(10))) == [.stopCurrent])
        #expect(m.running == Self.record)
        #expect(m.runningID == nil)
        #expect(m.history.spans.count == 2)
    }

    @Test("Every failure returns to the previous target and records nothing",
          arguments: [SwitchFailure.noInternet, .noModel(.whisper), .noQuota, .signedOut, .needsKey, .timedOut, .other])
    func failureReturns(reason: SwitchFailure) {
        var m = machine()
        _ = m.handle(.click(Self.local, failure: nil, at: at(5)))
        #expect(m.handle(.sessionFailed(id: 2, reason)).isEmpty)
        #expect(m.selected == Self.cloud)
        #expect(m.running == Self.cloud)
        #expect(m.failure == reason)
        #expect(m.history.spans.count == 1)
        #expect(m.markers.isEmpty)
    }

    @Test("A failed pre-check connects nothing")
    func preCheckFails() {
        var m = machine()
        #expect(m.handle(.click(Self.local, failure: .noModel(.whisper), at: at(5))).isEmpty)
        #expect(m.selected == Self.cloud)
        #expect(m.failure == .noModel(.whisper))
    }

    @Test("A click during connecting cancels; a new live target starts a new session")
    func clickDuringConnecting() {
        var m = machine()
        _ = m.handle(.click(Self.local, failure: nil, at: at(5)))
        let other = MeetingEngineTarget.live(.appleSpeech)
        #expect(m.handle(.click(other, failure: nil, at: at(6))) == [.cancelSession(id: 2), .startSession(id: 3, target: other)])
        #expect(m.handle(.click(Self.cloud, failure: nil, at: at(7))) == [.cancelSession(id: 3)])
        #expect(m.selected == Self.cloud)
        #expect(!m.isConnecting)
        #expect(m.history.spans.count == 1)
        #expect(m.markers.isEmpty)
    }

    @Test("Record only during connecting cancels and cuts now")
    func recordOnlyDuringConnecting() {
        var m = machine()
        _ = m.handle(.click(Self.local, failure: nil, at: at(5)))
        #expect(m.handle(.click(Self.record, failure: nil, at: at(6))) == [.cancelSession(id: 2), .stopCurrent])
        #expect(m.running == Self.record)
    }

    @Test("A stale session's ready or failure is ignored")
    func staleIgnored() {
        var m = machine()
        _ = m.handle(.click(Self.local, failure: nil, at: at(5)))
        _ = m.handle(.click(Self.cloud, failure: nil, at: at(6)))
        #expect(m.handle(.sessionReady(id: 2, at: at(7))).isEmpty)
        #expect(m.handle(.sessionFailed(id: 2, .other)).isEmpty)
        #expect(m.running == Self.cloud)
        #expect(m.failure == nil)
    }

    @Test("End during connecting cancels, and nothing fires after it")
    func endDuringConnecting() {
        var m = machine()
        _ = m.handle(.click(Self.local, failure: nil, at: at(5)))
        #expect(m.handle(.end) == [.cancelSession(id: 2)])
        #expect(m.handle(.sessionReady(id: 2, at: at(6))).isEmpty)
        #expect(m.handle(.click(Self.record, failure: nil, at: at(7))).isEmpty)
        #expect(m.handle(.quotaExhausted(at: at(8))).isEmpty)
        #expect(m.history.spans.count == 1)
    }

    @Test("Quota cuts Diduny to Record only with a persistent line")
    func quota() {
        var m = machine()
        #expect(m.handle(.quotaExhausted(at: at(30))) == [.stopCurrent])
        #expect(m.running == .afterStopOnly(.parakeet))
        #expect(m.persistentNote == .quotaMoved)
    }

    @Test("Quota while Diduny is still connecting cancels it and returns")
    func quotaWhileConnecting() {
        var m = machine(Self.local)
        _ = m.handle(.click(Self.cloud, failure: nil, at: at(5)))
        #expect(m.handle(.quotaExhausted(at: at(6))) == [.cancelSession(id: 2)])
        #expect(m.running == Self.local)
        #expect(m.selected == Self.local)
    }

    @Test("Changing the Record only engine on Record only starts nothing and adds no line")
    func afterStopEngineChange() {
        var m = machine(Self.record)
        #expect(m.handle(.click(.afterStopOnly(.whisper), failure: nil, at: at(4))).isEmpty)
        #expect(m.afterStopEngine == .whisper)
        #expect(m.markers.isEmpty)
        #expect(m.history.spans.count == 1)
    }

    @Test("A drop marks the running span; a stale drop does not")
    func drops() {
        var m = machine()
        _ = m.handle(.dropped(id: 9, terminal: false, frame: 1))
        #expect(m.history.spans[0].disrupted == false)
        _ = m.handle(.dropped(id: 1, terminal: false, frame: 1))
        #expect(m.history.spans[0].disrupted)
        #expect(m.history.spans[0].failedAtFrame == nil)
        _ = m.handle(.dropped(id: 1, terminal: true, frame: 500))
        #expect(m.history.spans[0].failedAtFrame == 500)
        #expect(m.persistentNote == .offline)
    }

    // MARK: Markers

    @Test("A marker carries its time and its position")
    func markerPosition() {
        var m = machine(Self.local)
        _ = m.handle(.click(Self.cloud, failure: nil, at: at(380, turns: 2)))
        _ = m.handle(.sessionReady(id: 2, at: at(382, turns: 2)))
        _ = m.handle(.tailFinished(turns: 3))
        #expect(m.markers.count == 1)
        #expect(m.markers[0].elapsed == 382)
        #expect(m.markers[0].afterTurnCount == 3)
    }

    @Test("Live to live with no words leaves one line, the latest")
    func collapse() {
        var m = machine(Self.local)
        _ = m.handle(.click(Self.cloud, failure: nil, at: at(10)))
        _ = m.handle(.sessionReady(id: 2, at: at(11)))
        _ = m.handle(.click(.live(.elevenLabs), failure: nil, at: at(20)))
        _ = m.handle(.sessionReady(id: 3, at: at(21)))
        #expect(m.markers.count == 1)
        #expect(m.markers[0].kind == .switched(from: Self.local, to: .live(.elevenLabs)))
        #expect(m.markers[0].elapsed == 21)
    }

    @Test("Words between two switches keep both lines")
    func wordsKeepBoth() {
        var m = machine(Self.local)
        _ = m.handle(.click(Self.cloud, failure: nil, at: at(10)))
        _ = m.handle(.sessionReady(id: 2, at: at(11)))
        _ = m.handle(.wordsArrived)
        _ = m.handle(.click(.live(.elevenLabs), failure: nil, at: at(20)))
        _ = m.handle(.sessionReady(id: 3, at: at(21)))
        #expect(m.markers.count == 2)
    }

    @Test("A round trip inside 3 s leaves no line but stays in the history; outside it stays",
          arguments: [(2.9, 0, 3), (3.1, 2, 3)])
    func roundTrip(delay: Double, lines: Int, spans: Int) {
        var m = machine()
        _ = m.handle(.click(Self.record, failure: nil, at: at(100)))
        _ = m.handle(.click(Self.cloud, failure: nil, at: at(100 + delay)))
        _ = m.handle(.sessionReady(id: 2, at: at(100 + delay)))
        #expect(m.markers.count == lines)
        #expect(m.history.spans.count == spans)
    }

    @Test("Record only opens a gap and the way back closes it")
    func gap() throws {
        var m = machine()
        _ = m.handle(.click(Self.record, failure: nil, at: at(100)))
        #expect(m.markers.last?.gapStart == 100)
        #expect(m.markers.last?.gapEnd == nil)
        _ = m.handle(.click(Self.cloud, failure: nil, at: at(140)))
        _ = m.handle(.sessionReady(id: 2, at: at(143)))
        let opened = try #require(m.markers.first)
        #expect(opened.gapEnd == 143)
        #expect(m.markers.count == 2)
    }

    @Test("Record only with no text yet shows no line")
    func noTextNoLine() {
        var m = machine()
        _ = m.handle(.click(Self.record, failure: nil, at: at(10, turns: 0)))
        #expect(m.markers.isEmpty)
    }

    @Test("Clicking the running engine retries only after a terminal failure")
    func retryAfterTerminal() {
        var m = machine()
        #expect(m.handle(.click(Self.cloud, failure: nil, at: at(5))).isEmpty)
        _ = m.handle(.dropped(id: 1, terminal: true, frame: 10))
        #expect(m.handle(.click(Self.cloud, failure: nil, at: at(6))) == [.startSession(id: 2, target: Self.cloud)])
    }

    @Test("A pre-check failure keeps what to retry")
    func failedTargetKept() {
        var m = machine()
        _ = m.handle(.click(Self.local, failure: .other, at: at(5)))
        #expect(m.failedTarget == Self.local)
        var display = MeetingSwitchDisplay(machine: m)
        #expect(MeetingSwitchText.line(display, translateMeeting: false, canUseAppleSpeech: false, canUseElevenLabs: false)?.linkTitle == "Try again")
        display.failedTarget = nil
        #expect(MeetingSwitchText.line(display, translateMeeting: false, canUseAppleSpeech: false, canUseElevenLabs: false)?.linkTitle == nil)
    }

    @Test("A pair change is a live-to-live cut with its own line, and keeps the engine")
    func pairChange() {
        var m = machine()
        #expect(m.handle(.restartLive(label: "EN ↔ PL", failure: nil)) == [.startSession(id: 2, target: Self.cloud)])
        _ = m.handle(.sessionReady(id: 2, at: at(60)))
        #expect(m.markers.first?.kind == .pair("EN ↔ PL"))
        #expect(m.history.spans.count == 2)
    }
}

struct MeetingStopPlanTests {
    private func span(_ target: MeetingEngineTarget, _ frame: Int = 0, disrupted: Bool = false) -> MeetingEngineSpan {
        MeetingEngineSpan(target: target, startFrame: frame, disrupted: disrupted)
    }

    /// Everything runs, unless listed in `missing`.
    private func plan(_ spans: [MeetingEngineSpan], accepted: Bool = true, hasText: Bool = true,
                      recordOnly: EngineID = .parakeet, missing: Set<EngineID> = []) -> MeetingStopPlan {
        MeetingStopPlan.plan(history: MeetingEngineHistory(spans: spans), recordOnlyEngine: recordOnly,
                             resolve: { missing.contains($0) ? .none(.unavailable) : .engine($0, modelID: nil) },
                             liveTextAccepted: accepted, hasLiveText: hasText)
    }

    @Test("A single clean cloud span keeps its live text")
    func cleanCloud() {
        #expect(plan([span(.live(.didunyCloud))]) == .keepLiveText(.didunyCloud))
        #expect(plan([span(.live(.elevenLabs))]) == .keepLiveText(.elevenLabs))
    }

    @Test("Local then Cloud: the cloud engine redoes all of it (Roman, 2026-11-09)")
    func localToCloud() {
        #expect(plan([span(.live(.whisper)), span(.live(.didunyCloud), 10)]) == .wholeRecording(.didunyCloud, modelID: nil, reason: .mixed))
    }

    @Test("Cloud then Local: the Local engine on this Mac, never uploaded")
    func cloudToLocal() {
        #expect(plan([span(.live(.didunyCloud)), span(.live(.whisper), 10)]) == .wholeRecording(.whisper, modelID: nil, reason: .mixed))
        #expect(plan([span(.live(.didunyCloud)), span(.live(.whisper), 10)], recordOnly: .didunyCloud, missing: [.whisper, .parakeet])
            == .wholeRecording(.appleSpeech, modelID: nil, reason: .mixed))
        #expect(plan([span(.live(.didunyCloud)), span(.live(.whisper), 10)], recordOnly: .didunyCloud,
                     missing: [.whisper, .parakeet, .appleSpeech]) == .saveOnly)
    }

    @Test("Local engine that cannot run after Stop: a local Record only engine stands in")
    func localStandIn() {
        #expect(plan([span(.live(.appleSpeech))], recordOnly: .whisper, missing: [.appleSpeech]) == .wholeRecording(.whisper, modelID: nil, reason: .liveDraft))
    }

    @Test("Local then Record only: its engine, local or cloud")
    func localToRecordOnly() {
        #expect(plan([span(.live(.whisper)), span(.afterStopOnly(.parakeet), 10)]) == .wholeRecording(.parakeet, modelID: nil, reason: .mixed))
        #expect(plan([span(.live(.whisper)), span(.afterStopOnly(.didunyCloud), 10)]) == .wholeRecording(.didunyCloud, modelID: nil, reason: .mixed))
    }

    @Test("Record only then Local: Local decides")
    func recordOnlyToLocal() {
        #expect(plan([span(.afterStopOnly(.didunyCloud)), span(.live(.whisper), 10)], recordOnly: .didunyCloud)
            == .wholeRecording(.whisper, modelID: nil, reason: .mixed))
    }

    @Test("A disrupted cloud span is redone by that engine; with nothing to run its text stays")
    func disruptedCloud() {
        #expect(plan([span(.live(.didunyCloud), disrupted: true)]) == .wholeRecording(.didunyCloud, modelID: nil, reason: .mixed))
        #expect(plan([span(.live(.didunyCloud), disrupted: true)], missing: [.didunyCloud]) == .keepLiveText(.didunyCloud))
        #expect(plan([span(.live(.didunyCloud), disrupted: true)], hasText: false, missing: [.didunyCloud]) == .saveOnly)
    }

    @Test("Rejected cloud text: the cloud engine redoes it")
    func rejected() {
        #expect(plan([span(.live(.didunyCloud))], accepted: false) == .wholeRecording(.didunyCloud, modelID: nil, reason: .liveTextRejected))
    }

    @Test("Local alone is a draft its own engine redoes in full")
    func localDraft() {
        #expect(plan([span(.live(.whisper))]) == .wholeRecording(.whisper, modelID: nil, reason: .liveDraft))
        #expect(plan([span(.live(.appleSpeech))]) == .wholeRecording(.appleSpeech, modelID: nil, reason: .liveDraft))
    }

    @Test("Record only runs its engine; nothing to run saves only")
    func recordOnly() {
        #expect(plan([span(.afterStopOnly(.whisper))]) == .wholeRecording(.whisper, modelID: nil, reason: .recordOnly))
        #expect(plan([span(.afterStopOnly(.parakeet))], missing: [.parakeet]) == .saveOnly)
    }

    @Test("A round trip with no marker still redoes the whole meeting")
    func roundTripIsMixed() {
        var m = MeetingSwitchMachine(start: .live(.didunyCloud), afterStopEngine: .parakeet)
        _ = m.handle(.click(.afterStopOnly(.parakeet), failure: nil, at: MeetingCutPoint(frame: 16000, elapsed: 1, turns: 1)))
        _ = m.handle(.click(.live(.didunyCloud), failure: nil, at: MeetingCutPoint(frame: 32000, elapsed: 2, turns: 1)))
        _ = m.handle(.sessionReady(id: 2, at: MeetingCutPoint(frame: 32000, elapsed: 2, turns: 1)))
        #expect(m.markers.isEmpty)
        #expect(plan(m.history.spans) == .wholeRecording(.didunyCloud, modelID: nil, reason: .mixed))
    }

    @Test("A failed or cancelled switch leaves one span, so the text is kept")
    func failedSwitchStaysSingle() {
        var m = MeetingSwitchMachine(start: .live(.didunyCloud), afterStopEngine: .parakeet)
        let point = MeetingCutPoint(frame: 10, elapsed: 1, turns: 1)
        _ = m.handle(.click(.live(.whisper), failure: nil, at: point))
        _ = m.handle(.sessionFailed(id: 2, .noModel(.whisper)))
        _ = m.handle(.end)
        #expect(plan(m.history.spans) == .keepLiveText(.didunyCloud))
    }

    @Test("The Stop line names the mode the meeting ended on")
    func stopLineNamesMode() {
        let line = MeetingStopPlan.wholeRecording(.whisper, modelID: nil, reason: .mixed).stopLine(preview: nil, mode: .thisMac)
        #expect(line == "You ended on Local, so Whisper makes one transcript from the whole recording, on this Mac. It replaces the live text.")
    }
}

struct TranslatePlanTests {
    private func plan(_ spans: [MeetingEngineSpan], texts: [Int: String], total: Int = 1600, skipped: Int = 0) -> [TranslatePart] {
        TranslatePlan.plan(history: MeetingEngineHistory(spans: spans), liveTexts: texts, afterStopEngine: .parakeet,
                           totalFrames: total, sampleRate: 16, skippedChunks: skipped)
    }

    @Test("Live then after Stop: the text, then only the rest of the audio")
    func liveThenRest() {
        let spans = [MeetingEngineSpan(target: .live(.didunyCloud), startFrame: 0),
                     MeetingEngineSpan(target: .afterStopOnly(.parakeet), startFrame: 160)]
        #expect(plan(spans, texts: [0: "hi"]) == [
            .live(text: "hi"),
            .afterStop(range: AudioTrimRange(startSeconds: 10, endSeconds: 100), engine: .parakeet),
        ])
    }

    @Test("Several cuts stay in time order")
    func multipleCuts() {
        let spans = [MeetingEngineSpan(target: .afterStopOnly(.whisper), startFrame: 0),
                     MeetingEngineSpan(target: .live(.didunyCloud), startFrame: 160),
                     MeetingEngineSpan(target: .live(.didunyCloud), startFrame: 320),
                     MeetingEngineSpan(target: .afterStopOnly(.parakeet), startFrame: 480)]
        #expect(plan(spans, texts: [1: "a", 2: "b"]) == [
            .afterStop(range: AudioTrimRange(startSeconds: 0, endSeconds: 10), engine: .whisper),
            .live(text: "a"), .live(text: "b"),
            .afterStop(range: AudioTrimRange(startSeconds: 30, endSeconds: 100), engine: .parakeet),
        ])
    }

    @Test("A terminal failure turns the rest of its span into audio on the Record only engine")
    func terminalFailure() {
        let spans = [MeetingEngineSpan(target: .live(.didunyCloud), startFrame: 0, disrupted: true, failedAtFrame: 800)]
        #expect(plan(spans, texts: [0: "a"]) == [
            .live(text: "a"),
            .afterStop(range: AudioTrimRange(startSeconds: 50, endSeconds: 100), engine: .parakeet),
        ])
    }

    @Test("Skipped chunks make offsets unusable: no parts, so one whole translation")
    func skippedChunks() {
        #expect(plan([MeetingEngineSpan(target: .live(.didunyCloud), startFrame: 0)], texts: [0: "a"], skipped: 1).isEmpty)
    }

    @Test("A zero-length span is dropped")
    func zeroLength() {
        let spans = [MeetingEngineSpan(target: .afterStopOnly(.whisper), startFrame: 0),
                     MeetingEngineSpan(target: .live(.didunyCloud), startFrame: 0)]
        #expect(plan(spans, texts: [1: "a"]) == [.live(text: "a")])
    }
}

/// C10, C16, C22 and the parts action through the real queue, with fake engines.
@MainActor
struct MeetingQueueSeamTests {
    private final class Calls { var engines: [String] = []; var diarize: [Bool] = [] }
    private enum Failure: Error { case boom }

    private func storage() throws -> RecordingsLibraryStorage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingQueueSeam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RecordingsLibraryStorage(baseDirectory: directory, batchStorage: try TranscriptionBatchStorage(baseDirectory: directory))
    }

    private func runner(_ calls: Calls, whisper: @escaping () throws -> String = { "whisper text" }) -> QueueEngineRunner {
        QueueEngineRunner(
            cloud: { config in
                calls.engines.append("cloud")
                calls.diarize.append(config["enable_speaker_diarization"] as? Bool ?? false)
                return GeneratedTranscript(text: "cloud text")
            },
            whisper: { calls.engines.append("whisper"); return try GeneratedTranscript(text: whisper()) },
            whisperTranslateToEnglish: { "" },
            onDevice: { calls.engines.append($0); return "device text" },
            elevenLabs: { diarize in
                calls.engines.append("elevenlabs")
                calls.diarize.append(diarize)
                return GeneratedTranscript(text: "el text")
            },
            translator: PassthroughTranslator()
        )
    }

    private struct PassthroughTranslator: TextTranslationProtocol {
        func translate(text: String, sourceLanguage _: String, targetLanguage: String) async throws -> String {
            "\(text) [\(targetLanguage)]"
        }
    }

    private func waitUntilDone(_ queue: RecordingQueueService) async {
        for _ in 0 ..< 400 where queue.isProcessing {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("The runner sends each engine to itself", arguments: EngineID.allCases)
    func runnerRoutes(engine: EngineID) async throws {
        let calls = Calls()
        _ = try await runner(calls).transcribe(engine, diarize: true, hints: [])
        let expected = switch engine {
        case .didunyCloud: "cloud"
        case .elevenLabs: "elevenlabs"
        case .whisper: "whisper"
        case .parakeet, .appleSpeech: engine.rawValue
        }
        #expect(calls.engines == [expected])
    }

    @Test("C22: signed out, a named Whisper transcribes through the runner")
    func signedOutWhisper() async throws {
        let storage = try storage()
        let id = try #require(storage.saveRecording(audioData: Data("RIFF....WAVEfmt ".utf8), type: .meeting, duration: 42, forceSave: true))
        let calls = Calls()
        let queue = RecordingQueueService(storage: storage, localModelIsAvailable: { _ in true }, hasSession: { false }, makeRunner: { _ in runner(calls) })
        #expect(queue.enqueue([id], action: .transcribeDiarize, engineOverride: .whisper))
        await waitUntilDone(queue)
        #expect(calls.engines == ["whisper"])
        #expect(storage.recordings.first { $0.id == id }?.status == .transcribed)
    }

    @Test("Signed out, a named Diduny Cloud still refuses")
    func signedOutCloud() throws {
        let storage = try storage()
        let id = try #require(storage.saveRecording(audioData: Data("RIFF....WAVEfmt ".utf8), type: .meeting, duration: 42, forceSave: true))
        let queue = RecordingQueueService(storage: storage, startsAutomatically: false, localModelIsAvailable: { _ in true }, hasSession: { false })
        #expect(!queue.enqueue([id], action: .transcribeDiarize, engineOverride: .didunyCloud))
        #expect(storage.recordings.first { $0.id == id }?.status == .failed)
    }

    @Test("C16: Diduny out of quota retries on this Mac")
    func quotaFallback() async throws {
        let storage = try storage()
        let id = try #require(storage.saveRecording(audioData: Data("RIFF....WAVEfmt ".utf8), type: .meeting, duration: 42, forceSave: true))
        let calls = Calls()
        var base = runner(calls)
        base.cloud = { _ in throw TranscriptionError.usageLimitExceeded(usedHours: 5, limitHours: 5) }
        let fake = base
        let queue = RecordingQueueService(storage: storage, localModelIsAvailable: { _ in true }, hasSession: { true }, makeRunner: { _ in fake })
        #expect(queue.enqueue([id], action: .transcribeDiarize, localFallbackOnUsageLimit: true, engineOverride: .didunyCloud))
        await waitUntilDone(queue)
        #expect(calls.engines == ["whisper"])
        #expect(storage.recordings.first { $0.id == id }?.status == .transcribed)
    }

    @Test("A failed redo saves the meeting's live text and keeps the audio")
    func failedRedoKeepsText() async throws {
        let storage = try storage()
        let id = try #require(storage.saveRecording(audioData: Data("RIFF....WAVEfmt ".utf8), type: .meeting, duration: 42, forceSave: true))
        let queue = RecordingQueueService(storage: storage, localModelIsAvailable: { _ in true }, hasSession: { true },
                                          makeRunner: { _ in runner(Calls(), whisper: { throw Failure.boom }) })
        #expect(queue.enqueue([id], action: .transcribeDiarize, engineOverride: .whisper, textIfItFails: "live words"))
        await waitUntilDone(queue)
        let saved = try #require(storage.recordings.first { $0.id == id })
        #expect(saved.status == .failed)
        #expect(saved.transcriptionText == "live words")
        #expect(storage.hasPlayableAudio(for: saved))
    }

    @Test("After-Stop Translate meeting: the engine picked last runs, not the one it started on")
    func translatePickRuns() throws {
        let storage = try storage()
        let id = try #require(storage.saveRecording(audioData: Data("RIFF....WAVEfmt ".utf8), type: .meetingTranslation, duration: 42, forceSave: true))
        let queue = RecordingQueueService(storage: storage, startsAutomatically: false, localModelIsAvailable: { _ in true }, hasSession: { true })
        var machine = MeetingSwitchMachine(start: .afterStopOnly(.elevenLabs), afterStopEngine: .elevenLabs)
        _ = machine.handle(.click(.afterStopOnly(.whisper), failure: nil, at: MeetingCutPoint(frame: 0, elapsed: 1, turns: 0)))
        var asked: EngineID?
        #expect(AppDelegate().enqueueTranslateMeetingAfterStop(
            id, target: "uk", history: machine.history, liveTexts: [:], afterStopEngine: machine.afterStopEngine, queue: queue,
            resolve: { asked = $0; return .engine($0, modelID: nil) }
        ))
        #expect(asked == .whisper)
        #expect(queue.isQueued(id))
    }

    @Test("No engine: an after-Stop Translate meeting stays out of the queue, not failed")
    func translateNoEngine() throws {
        let storage = try storage()
        let id = try #require(storage.saveRecording(audioData: Data("RIFF....WAVEfmt ".utf8), type: .meetingTranslation, duration: 42, forceSave: true))
        let queue = RecordingQueueService(storage: storage, startsAutomatically: false, hasSession: { true })
        let machine = MeetingSwitchMachine(start: .afterStopOnly(.whisper), afterStopEngine: .whisper)
        #expect(!AppDelegate().enqueueTranslateMeetingAfterStop(
            id, target: "uk", history: machine.history, liveTexts: [:], afterStopEngine: .whisper, queue: queue,
            resolve: { _ in .none(.notDownloaded(bytes: 0)) }
        ))
        #expect(storage.recordings.first { $0.id == id }?.status != .failed)
    }

    @Test("Mid-meeting readiness checks the model and the session; resolver then reaches saveOnly")
    func realReadiness() {
        struct AllReady: EngineReadinessSource { func readiness(of _: EngineID) -> EngineReadiness { .ready } }
        let source = MeetingEngineReadiness(base: AllReady(), hasWhisperModel: { false }, signedIn: { false }, hasQuota: { false })
        #expect(source.readiness(of: .whisper) == .notDownloaded(bytes: 0))
        #expect(source.readiness(of: .didunyCloud) == .signedOut)
        #expect(MeetingEngineController.failure(from: source.readiness(of: .didunyCloud), engine: .didunyCloud) == .signedOut)
        let noQuota = MeetingEngineReadiness(base: AllReady(), hasWhisperModel: { true }, signedIn: { true }, hasQuota: { false })
        #expect(MeetingEngineController.failure(from: noQuota.readiness(of: .didunyCloud), engine: .didunyCloud) == .noQuota)
        let defaults = UserDefaults(suiteName: "MeetingReadiness-\(UUID().uuidString)")!
        let result = EffectiveEngineResolver.resolve(
            job: .meeting, segment: .recordOnly, override: JobProviderSelection(providerID: EngineID.whisper.rawValue, modelID: nil),
            allowsStandIn: true, defaults: ModeDefaults(defaults: defaults), readiness: source,
            whisper: .init(downloaded: [], selected: nil)
        )
        #expect(MeetingStopPlan.plan(history: MeetingEngineHistory(spans: [MeetingEngineSpan(target: .afterStopOnly(.whisper), startFrame: 0)]),
                                     recordOnlyEngine: .whisper, resolve: { _ in result }, liveTextAccepted: false) == .saveOnly)
    }

    @Test("Parts keep live text, translate only the ranges, and save as translated")
    func parts() async throws {
        let storage = try storage()
        let id = try #require(storage.saveRecording(audioData: Data("RIFF....WAVEfmt ".utf8), type: .meetingTranslation, duration: 42, forceSave: true))
        let calls = Calls()
        let queue = RecordingQueueService(storage: storage, localModelIsAvailable: { _ in true }, hasSession: { true }, makeRunner: { _ in runner(calls) })
        #expect(queue.enqueue([id], action: .translateParts([.live(text: "kept"), .afterStop(range: nil, engine: .parakeet)], target: "uk")))
        await waitUntilDone(queue)
        let saved = try #require(storage.recordings.first { $0.id == id })
        #expect(saved.status == .translated)
        #expect(saved.transcriptionText?.contains("kept") == true)
        #expect(saved.transcriptionText?.contains("device text [uk]") == true)
    }

    @Test("A failed part keeps what is ready, marks it failed, and stops")
    func failedPart() async {
        let result = await QueueEngineRunner.translateParts([
            .live(text: "kept"), .afterStop(range: nil, engine: .parakeet), .live(text: "later"),
        ]) { _, _ in throw Failure.boom }
        #expect(result.text == "kept\n\nlater")
        #expect(result.error is Failure)
    }
}

struct MeetingAudioFanOutTests {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var total: Int { lock.withLock { count } }
    }

    @Test("Each buffer reaches exactly one consumer across swaps")
    func oneConsumer() async {
        let fanOut = MeetingAudioFanOut()
        let first = Sink(), second = Sink()
        fanOut.setConsumer { _ in first.add() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for _ in 0 ..< 2000 { fanOut.deliver(Data([1])) } }
            group.addTask {
                for index in 0 ..< 200 {
                    fanOut.setConsumer(index.isMultiple(of: 2) ? { _ in second.add() } : { _ in first.add() })
                }
            }
        }
        #expect(first.total + second.total == 2000)
    }

    @Test("The swap returns the frame it read; no consumer drops the audio")
    func swapReadsFrame() {
        let fanOut = MeetingAudioFanOut()
        let sink = Sink()
        #expect(fanOut.setConsumer({ _ in sink.add() }, readFrame: { 1234 }) == 1234)
        fanOut.deliver(Data([1]))
        fanOut.setConsumer(nil)
        fanOut.deliver(Data([1]))
        #expect(sink.total == 1)
    }

    private static func tone(_ amplitude: Int16, frames: Int = 1600) -> Data {
        var samples = (0 ..< frames).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
        return Data(bytes: &samples, count: frames * 2)
    }

    @Test("Mixed audio sets the level with no consumer (Record only); silence drops it")
    func levelWithoutConsumer() {
        let fanOut = MeetingAudioFanOut()
        fanOut.deliver(Self.tone(Int16.max / 10)) // -20 dB
        #expect(abs(fanOut.level - 40.0 / 60.0) < 0.01)
        fanOut.deliver(Self.tone(0))
        #expect(fanOut.level == 0)
    }

    @MainActor
    @Test("The level pump carries the fan-out level to the panel sink, and zeroes it on cancel")
    func levelPumpReachesSink() async throws {
        let fanOut = MeetingAudioFanOut()
        var seen: [Float] = []
        let task = MeetingAudioFanOut.startLevelPump(fanOut, interval: .milliseconds(5)) { seen.append($0) }
        fanOut.deliver(Self.tone(Int16.max / 10))
        for _ in 0 ..< 200 where !seen.contains(where: { $0 > 0.5 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(seen.contains { $0 > 0.5 })
        task.cancel()
        await task.value
        #expect(seen.last == 0)
    }
}

@MainActor
struct LiveTranscriptCommitTests {
    @Test("Whisper's provisional text stays at a cut and the next batch does not replace it")
    func commitKeepsText() {
        let store = LiveTranscriptStore()
        store.processTokens([RealtimeToken(text: "draft words", isFinal: false)])
        store.commitProvisional()
        store.markSegmentBoundary()
        store.processTokens([RealtimeToken(text: "new words", isFinal: false)])
        #expect(store.segments.map(\.text) == ["draft words"])
        #expect(store.provisionalText == "new words")
        #expect(store.wordCount == 4)
    }

    @Test("Nothing provisional, nothing added")
    func commitEmpty() {
        let store = LiveTranscriptStore()
        store.commitProvisional()
        #expect(store.segments.isEmpty)
    }
}

struct WhisperHoldTests {
    @Test("An old session's release does not end the new session's hold")
    func holdsBalance() {
        let whisper = WhisperTranscriptionService()
        let old = UUID(), new = UUID()
        try? whisper.insertStreamingHoldForTesting(old)
        try? whisper.insertStreamingHoldForTesting(new)
        whisper.endStreamingHold(old)
        #expect(whisper.hasStreamingHold)
        whisper.endStreamingHold(new)
        #expect(!whisper.hasStreamingHold)
    }
}
