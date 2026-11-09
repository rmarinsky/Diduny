@testable import Diduny
import Foundation
import os
import Testing

/// WP-64 (N21): switching the engine during a dictation or a translation.
@MainActor
struct DictationEngineSwitchTests {
    // MARK: - Fakes

    @MainActor
    final class FakeSession: MeetingEngineSession {
        let target: MeetingEngineTarget
        let bytes = OSAllocatedUnfairLock(initialState: 0)
        nonisolated let audioConsumer: @Sendable (Data) -> Void
        private var continuation: CheckedContinuation<Void, Error>?
        var cancels = 0
        var finishes = 0

        init(_ target: MeetingEngineTarget) {
            self.target = target
            let bytes = bytes
            audioConsumer = { data in bytes.withLock { $0 += data.count } }
        }

        /// A result that came before the controller called `start`.
        private var early: Result<Void, Error>?

        func start() async throws {
            if let early { return try early.get() }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func resolve(_ result: Result<Void, Error>) {
            guard let continuation else {
                early = result
                return
            }
            continuation.resume(with: result)
            self.continuation = nil
        }

        func finish(cap _: Duration?) async -> Bool {
            finishes += 1
            return true
        }

        func cancel() async { cancels += 1 }
    }

    @MainActor
    final class Harness {
        var made: [(session: FakeSession, sink: DictationSpanSink)] = []
        var startStops = 0
        var cuts: [MeetingEngineTarget] = []
        var readinessFailure: SwitchFailure?
        let startBytes = OSAllocatedUnfairLock(initialState: 0)
        var switcher: DictationEngineSwitcher!
        var tap: ((Data) -> Void)!

        init(start: MeetingEngineTarget = .live(.didunyCloud), startText: String = "hello there") {
            switcher = DictationEngineSwitcher(
                start: start,
                startSession: .init(
                    stop: { [unowned self] in
                        startStops += 1
                        return RealtimeSessionStopResult(
                            text: startText, preFinalizeText: startText, optimisticCleanedText: nil, finalizeResult: .skipped)
                    },
                    cancel: {}
                ),
                environment: .init(
                    readiness: { [unowned self] _ in readinessFailure },
                    makeSession: { [unowned self] target, _ in
                        let made = (session: FakeSession(target), sink: DictationSpanSink())
                        self.made.append(made)
                        return made
                    },
                    applyTokens: { _ in },
                    applyStatus: { _ in },
                    closeTurn: {},
                    didCut: { [unowned self] in cuts.append($0) },
                    didChange: { _ in }
                )
            )
            let startBytes = startBytes
            tap = switcher.audioCallback(startConsumer: { data in startBytes.withLock { $0 += data.count } })
        }

        /// 16 kHz mono 16-bit: `frames` frames.
        func feed(frames: Int) { tap(Data(count: frames * 2)) }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - State machine

    @Test("A pick connects while the old engine keeps the audio, then cuts at ready")
    func switchCutsAtReady() async {
        let harness = Harness()
        harness.feed(frames: 50)
        harness.switcher.click(.live(.appleSpeech))
        #expect(harness.switcher.controller?.machine.isConnecting == true)
        #expect(harness.switcher.selected == .live(.appleSpeech))
        harness.feed(frames: 30)
        #expect(harness.startBytes.withLock { $0 } == 160)
        #expect(harness.made.first?.session.bytes.withLock { $0 } == 0)

        harness.made[0].session.resolve(.success(()))
        await eventually { harness.switcher.didSwitch }
        #expect(harness.switcher.didSwitch)
        #expect(harness.cuts == [.live(.appleSpeech)])
        #expect(harness.switcher.history.spans.map(\.startFrame) == [0, 80])
        harness.feed(frames: 20)
        #expect(harness.startBytes.withLock { $0 } == 160)
        #expect(harness.made[0].session.bytes.withLock { $0 } == 40)
        await eventually { harness.startStops == 1 }
        #expect(harness.startStops == 1) // The old engine's tail is finished, once.
    }

    @Test("Text so far comes first, the new engine's after it, nothing repeated at the cut")
    func textOrderAcrossTheCut() async {
        let harness = Harness(startText: "hello there")
        harness.switcher.click(.live(.appleSpeech))
        harness.made[0].session.resolve(.success(()))
        await eventually { harness.switcher.didSwitch }
        harness.made[0].sink.add([RealtimeToken(text: "general ", isFinal: true), RealtimeToken(text: "kenobi", isFinal: false)])
        await harness.switcher.shutdown(finalize: true)

        let start = await harness.switcher.startResult()
        let later = harness.switcher.laterSpanTexts
        let texts = DictationSwitchPlan.parts(harness.switcher.history).map { part -> String in
            switch part {
            case .live(span: 0): start?.text ?? ""
            case let .live(span): later[span]?.text ?? ""
            case .afterStop: ""
            }
        }
        #expect(DictationSwitchPlan.compose(texts) == "hello there general kenobi")
        #expect(harness.made[0].session.finishes == 1)
    }

    @Test("A failed connect keeps the old engine and its audio, with a reason")
    func failureKeepsTheOldEngine() async {
        let harness = Harness()
        harness.switcher.click(.live(.appleSpeech))
        harness.made[0].session.resolve(.failure(URLError(.notConnectedToInternet)))
        await eventually { harness.switcher.controller?.machine.isConnecting == false }
        let machine = harness.switcher.controller?.machine
        #expect(machine?.running == .live(.didunyCloud))
        #expect(machine?.selected == .live(.didunyCloud))
        #expect(machine?.failure == .noInternet)
        #expect(!harness.switcher.didSwitch)
        harness.feed(frames: 10)
        #expect(harness.startBytes.withLock { $0 } == 20)
        #expect(harness.startStops == 0)
    }

    @Test("A failed pre-check connects nothing")
    func preCheckFailure() {
        let harness = Harness()
        harness.readinessFailure = .signedOut
        harness.switcher.click(.live(.whisper))
        #expect(harness.made.isEmpty)
        #expect(harness.switcher.controller?.machine.failure == .signedOut)
        #expect(!harness.switcher.didSwitch)
    }

    @Test("A connect that returns after a newer pick cancels itself and never cuts")
    func staleConnectSelfCancels() async {
        let harness = Harness()
        harness.switcher.click(.live(.appleSpeech))
        harness.switcher.click(.live(.whisper))
        #expect(harness.made.count == 2)
        await eventually { harness.made[0].session.cancels == 1 }
        harness.made[0].session.resolve(.success(()))
        await eventually { harness.made[0].session.cancels == 2 }
        #expect(harness.made[0].session.cancels == 2)
        #expect(!harness.switcher.didSwitch)
        harness.made[1].session.resolve(.success(()))
        await eventually { harness.switcher.didSwitch }
        #expect(harness.cuts == [.live(.whisper)])
    }

    @Test("A local pick stays local: its own session, or its own engine after Stop")
    func localPickStaysLocal() {
        let harness = Harness()
        harness.switcher.click(.live(.appleSpeech))
        #expect(harness.made.map(\.session.target) == [.live(.appleSpeech)])

        let parakeet = DictationSwitchPlan.target(for: .parakeet, elevenLabsLive: false, translating: false)
        #expect(parakeet == .afterStopOnly(.parakeet))
        let other = Harness()
        other.feed(frames: 40)
        other.switcher.click(parakeet)
        #expect(other.made.isEmpty) // No session, no network.
        #expect(other.cuts == [.afterStopOnly(.parakeet)])
        #expect(DictationSwitchPlan.parts(other.switcher.history)
            == [.live(span: 0), .afterStop(span: 1, engine: .parakeet, startFrame: 40, endFrame: nil)])
        #expect(DictationSwitchPlan.runsLocally(.parakeet))
        #expect(DictationSwitchPlan.runsLocally(.whisper))
        #expect(DictationSwitchPlan.runsLocally(.appleSpeech))
        #expect(!DictationSwitchPlan.runsLocally(.didunyCloud))
        #expect(DictationSwitchPlan.target(for: .whisper, elevenLabsLive: false, translating: true) == .afterStopOnly(.whisper))
    }

    @Test("Stop while connecting cancels the switch and finishes the old engine")
    func stopDuringConnecting() async {
        let harness = Harness()
        harness.switcher.click(.live(.appleSpeech))
        await harness.switcher.shutdown(finalize: true)
        await eventually { harness.made[0].session.cancels >= 1 }
        #expect(harness.made[0].session.cancels >= 1)
        #expect(harness.startStops == 1)
        #expect(!harness.switcher.didSwitch)
        #expect(await harness.switcher.startResult()?.text == "hello there")
        harness.made[0].session.resolve(.success(()))
        await eventually { harness.made[0].session.cancels >= 2 }
        #expect(!harness.switcher.didSwitch)
    }

    @Test("Without a pick nothing changes: no controller, the audio goes where it went")
    func noPickNoChange() {
        let harness = Harness()
        harness.feed(frames: 100)
        #expect(!harness.switcher.isActive)
        #expect(harness.startBytes.withLock { $0 } == 200)
        #expect(harness.switcher.capturedFrames == 100)
    }

    // MARK: - Plan

    @Test("Whisper and after-Stop spans are transcribed from their own audio")
    func partsRanges() {
        let history = MeetingEngineHistory(spans: [
            .init(target: .live(.didunyCloud), startFrame: 0),
            .init(target: .live(.whisper), startFrame: 100),
            .init(target: .afterStopOnly(.parakeet), startFrame: 300),
        ])
        #expect(DictationSwitchPlan.parts(history) == [
            .live(span: 0),
            .afterStop(span: 1, engine: .whisper, startFrame: 100, endFrame: 300),
            .afterStop(span: 2, engine: .parakeet, startFrame: 300, endFrame: nil),
        ])
    }

    @Test("Compose trims and skips empty parts")
    func composeParts() {
        #expect(DictationSwitchPlan.compose([" one two ", "", "three"]) == "one two three")
    }

    @Test("A WAV slice holds exactly the frames after the cut")
    func wavSlice() throws {
        let pcm = Data((0 ..< 10).flatMap { [UInt8($0), 0] })
        let wav = DictationSwitchPlan.wavFile(pcm: pcm)
        let slice = try #require(DictationSwitchPlan.slice(wav: wav, from: 4, to: nil))
        #expect(slice.count == 44 + 12)
        #expect(Array(slice.suffix(12)) == Array(pcm.suffix(12)))
        #expect(DictationSwitchPlan.slice(wav: wav, from: 2, to: 4).map { Array($0.suffix(4)) } == [2, 0, 3, 0])
        #expect(DictationSwitchPlan.slice(wav: wav, from: 10, to: nil) == nil)
        var stereo = wav
        stereo[22] = 2 // Channels: not the layout the cut counts in.
        #expect(DictationSwitchPlan.slice(wav: stereo, from: 0, to: nil) == nil)
    }

    // MARK: - Review fixes

    private static let marker = "[failed]"
    private static let threeSpans = MeetingEngineHistory(spans: [
        .init(target: .live(.didunyCloud), startFrame: 0),
        .init(target: .afterStopOnly(.parakeet), startFrame: 4),
        .init(target: .live(.appleSpeech), startFrame: 8),
    ])

    @Test("A part that fails becomes a marker; the parts with text are kept")
    func failedPartKeepsTheRest() async {
        let texts = await DictationSwitchPlan.collect(
            history: Self.threeSpans,
            liveTexts: [0: .init(text: "one", translated: false), 2: .init(text: "three", translated: false)],
            audio: Data(), failedMarker: Self.marker, slice: { _, _, _ in Data([1]) }
        ) { _, _ in throw URLError(.timedOut) }
        #expect(DictationSwitchPlan.compose(texts.map(\.text)) == "one [failed] three")
        #expect(texts[1].translated) // The marker is never sent for translation.
    }

    @Test("A first engine that never connected is transcribed from 0 to the cut by its own engine")
    func emptyStartIsRescued() async {
        var calls: [(EngineID, Int, Int?)] = []
        var ranges: [(Int, Int?)] = []
        let texts = await DictationSwitchPlan.collect(
            history: Self.threeSpans,
            liveTexts: [0: .init(text: "", translated: false), 2: .init(text: "three", translated: false)],
            audio: Data(), failedMarker: Self.marker,
            slice: { _, from, to in ranges.append((from, to)); return Data([UInt8(from)]) }
        ) { engine, audio in
            calls.append((engine, Int(audio[0]), nil))
            return engine == .didunyCloud ? "one" : "two"
        }
        #expect(calls.map(\.0) == [.didunyCloud, .parakeet])
        #expect(ranges.first.map { $0.0 == 0 && $0.1 == 4 } == true)
        #expect(DictationSwitchPlan.compose(texts.map(\.text)) == "one two three")
    }

    @Test("Audio that cannot be ranged is never sent to the cloud when a local engine was used")
    func unrangeableStaysLocal() async {
        var engines: [EngineID] = []
        let history = MeetingEngineHistory(spans: [
            .init(target: .afterStopOnly(.parakeet), startFrame: 0),
            .init(target: .live(.didunyCloud), startFrame: 4),
        ])
        let texts = await DictationSwitchPlan.collect(
            history: history, liveTexts: [1: .init(text: "two", translated: false)],
            audio: Data(), failedMarker: Self.marker, slice: { _, _, _ in nil }
        ) { engine, _ in engines.append(engine); return "whole" }
        #expect(engines == [.parakeet])
        #expect(texts.map(\.text) == ["whole"])
        #expect(DictationSwitchPlan.wholeFallbackEngine(used: [.whisper, .didunyCloud], preferred: .didunyCloud) == .whisper)
        #expect(DictationSwitchPlan.wholeFallbackEngine(used: [.didunyCloud, .elevenLabs], preferred: .elevenLabs) == .elevenLabs)
        #expect(DictationSwitchPlan.wholeFallbackEngine(used: [.appleSpeech, .didunyCloud], preferred: .parakeet) == .parakeet)
    }

    @Test("The cut frame equals exactly what the old consumer received, under concurrent delivery")
    func cutIsExact() async {
        let fanOut = MeetingAudioFanOut()
        let old = OSAllocatedUnfairLock(initialState: 0)
        fanOut.setConsumer { data in old.withLock { $0 += data.count } }
        let feeder = Task.detached {
            for _ in 0 ..< 20000 { fanOut.deliver(Data(count: 320)) }
        }
        try? await Task.sleep(for: .milliseconds(2))
        let cut = fanOut.setConsumer({ _ in }, readFrame: { fanOut.deliveredFrames })
        await feeder.value
        #expect(old.withLock { $0 } == cut * 2)
    }
}
