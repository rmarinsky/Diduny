@testable import Diduny
import Foundation
import Testing

/// The live meeting panels show the running session, not Settings > Modes (WP-30, WP-31, WP-32 fixes).
@MainActor
struct RunningMeetingPanelTests {
    @Test("Running segment from the session: Record only, Cloud, live on this Mac, audio only")
    func runningSegment() {
        #expect(RunningMeetingSession.segment(recordOnly: true, cloudMode: true, localPreview: true) == .recordOnly)
        #expect(RunningMeetingSession.segment(recordOnly: false, cloudMode: true, localPreview: false) == .cloud)
        #expect(RunningMeetingSession.segment(recordOnly: false, cloudMode: false, localPreview: true) == .thisMac)
        #expect(RunningMeetingSession.segment(recordOnly: false, cloudMode: false, localPreview: false) == .recordOnly)
    }

    @Test("Running engine: own live engine on Cloud, Whisper live on this Mac, the after-Stop pick in Record only")
    func runningEngine() {
        #expect(RunningMeetingSession.engine(segment: .cloud, ownLiveEngine: nil, afterStopEngine: nil) == .didunyCloud)
        #expect(RunningMeetingSession.engine(segment: .cloud, ownLiveEngine: .elevenLabs, afterStopEngine: nil) == .elevenLabs)
        #expect(RunningMeetingSession.engine(segment: .thisMac, ownLiveEngine: nil, afterStopEngine: nil) == .whisper)
        #expect(RunningMeetingSession.engine(segment: .recordOnly, ownLiveEngine: nil, afterStopEngine: "parakeet-v3") == .parakeet)
        #expect(RunningMeetingSession.engine(segment: .recordOnly, ownLiveEngine: nil, afterStopEngine: nil) == .whisper)
    }

    @Test("In a running meeting every segment is clickable and the engine field offers a choice where there is one")
    func switchingOpen() {
        let store = LiveDictationOverlayStore()
        store.showRunningMeeting(segment: .recordOnly, engine: .whisper)
        // Before the recording runs nothing routes a click, so no segment is clickable (WP-64 fix).
        #expect(store.meetingPanelState.segments.allSatisfy { !$0.isEnabled })
        store.meetingSwitchHandler = MeetingSwitchHandler(click: { _ in }, changePair: { _ in true })
        let state = store.meetingPanelState
        #expect(state.segment == .recordOnly)
        #expect(state.engine == .whisper)
        #expect(state.segments.allSatisfy { $0.isEnabled })
        #expect(!state.isFieldStatic)
    }

    @Test("Translate meeting offers the switchable engines, with the running one selected")
    func translateMeetingOffersEngines() throws {
        let store = LiveDictationOverlayStore()
        store.showRunningMeetingTranslation(engine: .didunyCloud)
        let model = try #require(store.translateMeetingPanelModel)
        #expect(model.engine.caps.id == .didunyCloud)
        #expect(model.engines.map(\.caps.id).contains(.whisper))
    }

    @Test("A click goes to the handler; the highlight follows the machine, not the click")
    func clicksGoToTheHandler() {
        let store = LiveDictationOverlayStore()
        var clicks: [MeetingEngineTarget] = []
        store.meetingSwitchHandler = MeetingSwitchHandler(click: { clicks.append($0) }, changePair: { _ in true })
        store.showRunningMeeting(segment: .cloud, engine: .didunyCloud)
        store.meetingEngines[.recordOnly] = .parakeet
        store.pickMeetingSegment(.recordOnly)
        #expect(clicks == [.afterStopOnly(.parakeet)])
        #expect(store.meetingSegment == .cloud)
        var machine = MeetingSwitchMachine(start: .live(.didunyCloud), afterStopEngine: .parakeet)
        _ = machine.handle(.click(.afterStopOnly(.parakeet), failure: nil, at: MeetingCutPoint(frame: 0, elapsed: 5, turns: 1)))
        store.applyMeetingSwitch(machine)
        #expect(store.meetingSegment == .recordOnly)
    }

    @Test("Markers show between the turns they fell between and stay out of Copy")
    func markerLines() {
        let store = LiveDictationOverlayStore()
        store.reset(mode: .meeting)
        store.processTokens([RealtimeToken(text: "before", isFinal: true, speaker: "1")])
        var machine = MeetingSwitchMachine(start: .live(.whisper), afterStopEngine: .parakeet)
        _ = machine.handle(.click(.live(.didunyCloud), failure: nil, at: MeetingCutPoint(frame: 0, elapsed: 380, turns: 1)))
        _ = machine.handle(.sessionReady(id: 2, at: MeetingCutPoint(frame: 0, elapsed: 382, turns: 1)))
        store.applyMeetingSwitch(machine)
        store.markSegmentBoundary()
        store.processTokens([RealtimeToken(text: "after", isFinal: true, speaker: "2")])
        #expect(store.meetingLines == [
            .speaker("Speaker 1"), .text("before"), .marker("06:22 · switched to Cloud"), .speaker("Speaker 2"), .text("after"),
        ])
        #expect(!store.displayText.contains("switched"))
    }

    @Test("Record only keeps the text with a note, and Copy still works")
    func textStaysOnRecordOnly() {
        let store = LiveDictationOverlayStore()
        store.reset(mode: .meeting)
        store.phase = .recording
        store.processTokens([RealtimeToken(text: "words", isFinal: true, speaker: "1")])
        var machine = MeetingSwitchMachine(start: .live(.didunyCloud), afterStopEngine: .parakeet)
        _ = machine.handle(.click(.afterStopOnly(.parakeet), failure: nil, at: MeetingCutPoint(frame: 0, elapsed: 60, turns: 1)))
        store.applyMeetingSwitch(machine)
        #expect(!store.meetingPanelState.showsCalmBox(hasText: !store.meetingLines.isEmpty))
        #expect(store.panelState.isCopyEnabled)
        #expect(store.meetingLines.contains(.note("No text here until you switch back. All of it goes into the transcript after Stop.")))
    }

    @Test("A failed switch names the reason and where it stayed")
    func failureLines() {
        var display = MeetingSwitchDisplay()
        display.running = .live(.whisper)
        display.failure = .noInternet
        let line = MeetingSwitchText.line(display, translateMeeting: false, canUseAppleSpeech: true, canUseElevenLabs: false)
        #expect(line == .init(message: "No internet. Still on Local."))
        display.failedTarget = .live(.didunyCloud)
        #expect(MeetingSwitchText.line(display, translateMeeting: false, canUseAppleSpeech: true, canUseElevenLabs: false)?.linkTitle == "Try again")
        display.running = .live(.didunyCloud)
        display.failure = .noModel(.whisper)
        #expect(MeetingSwitchText.line(display, translateMeeting: false, canUseAppleSpeech: true, canUseElevenLabs: false)
            == .init(message: "Whisper has no model yet. Still on Cloud.", linkTitle: "Use Apple Speech"))
        display.failure = nil
        display.note = .quotaMoved
        #expect(MeetingSwitchText.line(display, translateMeeting: false, canUseAppleSpeech: true, canUseElevenLabs: false)?.message
            == "Diduny quota used up. Recording continues without live text.")
    }
}

/// The controller with fake sessions: the hand-over, stale sessions, and where audio goes.
@MainActor
struct MeetingEngineControllerTests {
    final class FakeSession: MeetingEngineSession {
        let received = NSLockedList()
        nonisolated let audioConsumer: @Sendable (Data) -> Void
        var callbacks: MeetingSessionCallbacks
        var startGate: CheckedContinuation<Void, Error>?
        var startError: Error?
        var holdsStart = false
        var finished = 0
        var cancelled = 0

        init(callbacks: MeetingSessionCallbacks) {
            self.callbacks = callbacks
            let list = received
            audioConsumer = { _ in list.add() }
        }

        func start() async throws {
            if let startError { throw startError }
            if holdsStart { try await withCheckedThrowingContinuation { startGate = $0 } }
        }

        var holdsFinish = false
        var finishGate: CheckedContinuation<Void, Never>?

        func finish(cap _: Duration?) async -> Bool {
            if holdsFinish { await withCheckedContinuation { finishGate = $0 } }
            finished += 1
            return true
        }

        func cancel() async { cancelled += 1 }
    }

    final class NSLockedList: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @MainActor
    final class Rig {
        var sessions: [FakeSession] = []
        var statuses: [RealtimeConnectionStatus] = []
        var applied: [String] = []
        var holdNext = false
        var nextError: Error?
        var turns = 0
        var controller: MeetingEngineController!

        func make(start: MeetingEngineTarget, commitPair: @escaping (TranslationLanguagePair) -> Void = { _ in }) {
            controller = MeetingEngineController(start: start, afterStopEngine: .parakeet, environment: .init(
                readFrame: { 100 }, elapsed: { 10 }, turns: { self.turns }, finalText: { self.applied.joined() },
                readiness: { _ in nil },
                makeSession: { _, callbacks in
                    let session = FakeSession(callbacks: callbacks)
                    session.holdsStart = self.holdNext
                    session.startError = self.nextError
                    self.sessions.append(session)
                    return session
                },
                applyTokens: { events in
                    for case let .tokens(tokens) in events { self.applied += tokens.map(\.text) }
                },
                applyStatus: { self.statuses.append($0) },
                applyError: { _ in },
                closeTurn: {},
                didCut: { _ in },
                commitPair: commitPair,
                didChange: { _ in }
            ))
        }
    }

    private func settle() async {
        for _ in 0 ..< 50 { await Task.yield() }
    }

    @Test("A switch feeds only the new engine after the cut; the old one finishes")
    func handOver() async {
        let rig = Rig()
        rig.make(start: .live(.whisper))
        await rig.controller.startInitial(wait: true)
        rig.controller.fanOut.deliver(Data([1]))
        #expect(rig.sessions[0].received.count == 1)
        rig.holdNext = true
        rig.controller.click(.live(.didunyCloud))
        await settle()
        // Connecting: the old engine keeps the audio, the cloud gets nothing.
        rig.controller.fanOut.deliver(Data([1]))
        #expect(rig.sessions[0].received.count == 2)
        #expect(rig.sessions[1].received.count == 0)
        rig.sessions[1].startGate?.resume()
        await settle()
        rig.controller.fanOut.deliver(Data([1]))
        #expect(rig.sessions[0].received.count == 2)
        #expect(rig.sessions[1].received.count == 1)
        #expect(rig.sessions[0].finished == 1)
        #expect(rig.controller.machine.history.spans.map(\.startFrame) == [0, 100])
    }

    @Test("A Record only cut stops all live audio")
    func recordOnlySendsNothing() async {
        let rig = Rig()
        rig.make(start: .live(.didunyCloud))
        await rig.controller.startInitial(wait: true)
        rig.controller.click(.afterStopOnly(.parakeet))
        await settle()
        rig.controller.fanOut.deliver(Data([1]))
        #expect(rig.sessions[0].received.count == 0)
        #expect(rig.sessions[0].finished == 1)
    }

    @Test("A late ready after Stop disconnects itself and never becomes current")
    func staleReadyDisconnects() async {
        let rig = Rig()
        rig.make(start: .afterStopOnly(.parakeet))
        rig.holdNext = true
        rig.controller.click(.live(.didunyCloud))
        await settle()
        let pending = rig.sessions[0]
        let gate = pending.startGate
        await rig.controller.shutdown(finalize: false)
        gate?.resume()
        await settle()
        #expect(pending.cancelled >= 1)
        rig.controller.fanOut.deliver(Data([1]))
        #expect(pending.received.count == 0)
    }

    enum LateEnd: CaseIterable { case stop, cancel, newerClick }

    @Test("A connect returning late closes what it opened", arguments: LateEnd.allCases)
    func lateConnectCancels(end: LateEnd) async {
        let rig = Rig()
        rig.make(start: .afterStopOnly(.parakeet))
        rig.holdNext = true
        rig.controller.click(.live(.didunyCloud))
        await settle()
        let late = rig.sessions[0]
        let gate = late.startGate
        switch end {
        case .stop: await rig.controller.shutdown(finalize: true)
        case .cancel: await rig.controller.shutdown(finalize: false)
        case .newerClick: rig.controller.click(.afterStopOnly(.parakeet))
        }
        await settle()
        let before = late.cancelled
        gate?.resume()
        await settle()
        #expect(late.cancelled == before + 1, "The session itself disconnects after start returns")
        rig.controller.fanOut.deliver(Data([1]))
        #expect(late.received.count == 0)
    }

    @Test("A pair commits at the cut; a failure or a newer click drops it")
    func pairCommit() async {
        let pair = TranslationLanguagePair(languageA: "en", languageB: "pl")
        let rig = Rig()
        var committed: [TranslationLanguagePair] = []
        rig.make(start: .live(.didunyCloud)) { committed.append($0) }
        await rig.controller.startInitial(wait: true)
        rig.holdNext = true
        rig.controller.restartLive(pair: pair)
        await settle()
        #expect(committed.isEmpty)
        rig.controller.click(.live(.didunyCloud)) // Back: cancels.
        await settle()
        #expect(rig.controller.pendingPair == nil)
        rig.controller.restartLive(pair: pair)
        await settle()
        rig.sessions.last?.startGate?.resume()
        await settle()
        #expect(committed == [pair])
    }

    @Test("A cancelled session's status and text are dropped")
    func staleCallbacksDropped() async {
        let rig = Rig()
        rig.make(start: .live(.didunyCloud))
        await rig.controller.startInitial(wait: true)
        rig.holdNext = true
        rig.controller.click(.live(.whisper))
        await settle()
        let pending = rig.sessions[1]
        let gate = pending.startGate
        rig.controller.click(.live(.didunyCloud))
        await settle()
        pending.callbacks.status(.failed("late"))
        pending.callbacks.tokens([.tokens([RealtimeToken(text: "late", isFinal: true)])])
        gate?.resume()
        await settle()
        #expect(!rig.statuses.contains(.failed("late")))
        #expect(rig.applied.isEmpty)
        #expect(rig.controller.machine.history.spans.count == 1)
    }

    @Test("New text waits for the old tail, so the tail lands above the marker")
    func newTokensHeldUntilTail() async {
        let rig = Rig()
        rig.make(start: .live(.didunyCloud))
        await rig.controller.startInitial(wait: true)
        rig.holdNext = true
        rig.controller.click(.live(.elevenLabs))
        await settle()
        let old = rig.sessions[0], new = rig.sessions[1]
        old.holdsFinish = true
        new.startGate?.resume()
        await settle()
        new.callbacks.tokens([.tokens([RealtimeToken(text: "new", isFinal: true)])])
        old.callbacks.tokens([.tokens([RealtimeToken(text: "old", isFinal: true)])])
        #expect(rig.applied == ["old"])
        old.finishGate?.resume()
        await settle()
        #expect(rig.applied == ["old", "new"])
    }

    @Test("A 402 on reconnect moves the meeting to Record only")
    func quotaOnReconnect() async {
        let rig = Rig()
        rig.make(start: .live(.didunyCloud))
        await rig.controller.startInitial(wait: true)
        rig.sessions[0].callbacks.error(RealtimeTranscriptionError.usageLimitExceeded(usedHours: 5, limitHours: 5))
        await settle()
        #expect(rig.controller.machine.running == .afterStopOnly(.parakeet))
        #expect(rig.controller.machine.persistentNote == .quotaMoved)
    }

    @Test("A connect that fails returns the segment and never touches the running engine")
    func failedConnect() async {
        let rig = Rig()
        rig.make(start: .live(.whisper))
        await rig.controller.startInitial(wait: true)
        rig.nextError = RealtimeTranscriptionError.connectionFailed("offline")
        rig.controller.click(.live(.didunyCloud))
        await settle()
        #expect(rig.controller.machine.selected == .live(.whisper))
        #expect(rig.controller.machine.failure == .noInternet)
        rig.controller.fanOut.deliver(Data([1]))
        #expect(rig.sessions[0].received.count == 1)
    }

    @Test("Drop rules per engine: ElevenLabs reconnects are its rotation")
    func dropRules() {
        #expect(MeetingEngineController.dropSignal(.reconnecting(attempt: 1), engine: .didunyCloud) == false)
        #expect(MeetingEngineController.dropSignal(.reconnecting(attempt: 1), engine: .elevenLabs) == nil)
        #expect(MeetingEngineController.dropSignal(.failed("x"), engine: .elevenLabs) == true)
        #expect(MeetingEngineController.dropSignal(.connected, engine: .didunyCloud) == nil)
    }

    @Test("Stop snapshots each span's live text for Translate meeting")
    func snapshots() async {
        let rig = Rig()
        rig.make(start: .live(.didunyCloud))
        await rig.controller.startInitial(wait: true)
        rig.sessions[0].callbacks.tokens([.tokens([RealtimeToken(text: "hello", isFinal: true)])])
        await rig.controller.shutdown(finalize: true)
        #expect(rig.controller.liveTexts[0] == "hello")
    }
}
