import Foundation
import os

/// Collects one session's text for the result at Stop. Fed on the session's thread, in order.
final class DictationSpanSink: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (final: "", provisional: ""))
    /// Translation: only these tokens count; nil keeps every token (dictation, or a session that cannot translate).
    let translatedInto: String?

    init(translatedInto: String? = nil) {
        self.translatedInto = translatedInto
    }

    func add(_ tokens: [RealtimeToken]) {
        state.withLock { state in
            var provisional = ""
            for token in tokens where !token.text.isEmpty {
                if let target = translatedInto {
                    let status = token.translationStatus?.lowercased()
                    guard token.language == nil || token.language == target,
                          status == "translation" || status == "none" else { continue }
                }
                if token.isFinal { state.final += token.text } else { provisional += token.text }
            }
            state.provisional = provisional
        }
    }

    var spanText: DictationSwitchPlan.SpanText {
        let text = state.withLock { $0.final + $0.provisional }
        return .init(text: text.trimmingCharacters(in: .whitespacesAndNewlines), translated: translatedInto != nil)
    }
}

/// WP-64: engine switching during a dictation or a translation, on ADR-0013's pieces: `MeetingEngineController`
/// runs `MeetingSwitchMachine` against the sessions, `MeetingAudioFanOut` gives each buffer to one engine, and a
/// stale connect cancels itself. The session the recording started with stays on today's path; it becomes the
/// controller's first session only at the first pick, so a recording without a pick runs exactly as before.
@MainActor
final class DictationEngineSwitcher {
    struct Environment {
        var readiness: (MeetingEngineTarget) -> SwitchFailure?
        /// A new live session and the sink its tokens also feed; nil when the engine cannot run now.
        var makeSession: (MeetingEngineTarget, MeetingSessionCallbacks) -> (session: MeetingEngineSession, sink: DictationSpanSink)?
        var applyTokens: ([CoalescedTranscriptEvent]) -> Void
        var applyStatus: (RealtimeConnectionStatus) -> Void
        /// The old engine's tail is in: its provisional text stays.
        var closeTurn: () -> Void
        var didCut: (MeetingEngineTarget) -> Void
        var didChange: (MeetingSwitchMachine) -> Void
    }

    /// The start's own session: today's stop, run once as the tail of the first cut.
    struct StartSession {
        var stop: () async -> RealtimeSessionStopResult
        var cancel: () async -> Void
    }

    let start: MeetingEngineTarget
    let fanOut = MeetingAudioFanOut()
    private let env: Environment
    private let startSession: StartSession
    private var startConsumer: (@Sendable (Data) -> Void)?
    private(set) var controller: MeetingEngineController?
    private var startStop: Task<RealtimeSessionStopResult, Never>?
    /// Sinks by span index; span 0 is the start's.
    private var sinks: [Int: DictationSpanSink] = [:]
    private var lastSink: DictationSpanSink?

    init(start: MeetingEngineTarget, startSession: StartSession, environment: Environment) {
        self.start = start
        self.startSession = startSession
        env = environment
    }

    /// Install before the recorder starts (it snapshots the callback). Counts captured frames, then hands the
    /// buffer to whichever engine is current; `startConsumer` is today's callback.
    func audioCallback(startConsumer: ((Data) -> Void)?) -> (Data) -> Void {
        let consumer: (@Sendable (Data) -> Void)? = startConsumer.map { callback in
            nonisolated(unsafe) let callback = callback
            return { callback($0) }
        }
        self.startConsumer = consumer
        fanOut.setConsumer(consumer)
        let fanOut = fanOut
        return { data in fanOut.deliver(data) }
    }

    var capturedFrames: Int { fanOut.deliveredFrames }

    var didSwitch: Bool { (controller?.machine.history.spans.count ?? 1) > 1 }

    var history: MeetingEngineHistory { controller?.machine.history ?? .init(spans: [.init(target: start, startFrame: 0)]) }

    /// What the panel names now.
    var selected: MeetingEngineTarget { controller?.machine.selected ?? start }

    /// Every engine this recording ran on, after its cuts.
    var engines: [EngineID] { history.spans.map(\.target.engine) }

    func click(_ target: MeetingEngineTarget) {
        if controller == nil {
            guard target != start else { return }
            makeController()
        }
        controller?.click(target)
    }

    private func makeController() {
        var initialMade = !start.isLive
        let controller = MeetingEngineController(
            start: start, afterStopEngine: start.engine, fanOut: fanOut,
            environment: .init(
                readFrame: { [fanOut] in fanOut.deliveredFrames },
                elapsed: { 0 },
                turns: { 0 },
                finalText: { "" },
                readiness: env.readiness,
                makeSession: { [weak self] target, callbacks in
                    guard let self else { return nil }
                    if !initialMade {
                        initialMade = true
                        return StartAdapter(owner: self, consumer: startConsumer ?? { _ in })
                    }
                    let made = env.makeSession(target, callbacks)
                    lastSink = made?.sink
                    return made?.session
                },
                applyTokens: env.applyTokens,
                applyStatus: env.applyStatus,
                applyError: { _ in },
                closeTurn: env.closeTurn,
                didCut: { [weak self] target in
                    guard let self, let controller = self.controller else { return }
                    let span = controller.machine.history.spans.count - 1
                    if target.isLive { sinks[span] = lastSink }
                    env.didCut(target)
                },
                didChange: env.didChange
            )
        )
        self.controller = controller
        controller.beginInitial()
    }

    /// The start session's tail: today's stop, capped for the cut; Stop waits for all of it.
    fileprivate func finishStart(cap: Duration?) async {
        if startStop == nil {
            let stop = startSession.stop
            startStop = Task { await stop() }
        }
        guard let task = startStop else { return }
        if let cap {
            let done = OSAllocatedUnfairLock(initialState: false)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value; done.withLock { $0 = true } }
                group.addTask { try? await Task.sleep(for: cap) }
                await group.next()
                group.cancelAll()
            }
        } else {
            _ = await task.value
        }
        // Today's stop reports its own disconnect; the panel follows the engine that runs now.
        if let running = controller?.machine.running { env.applyStatus(running.isLive ? .connected : .disconnected) }
    }

    fileprivate func cancelStart() async {
        if startStop == nil { await startSession.cancel() }
    }

    /// Stop (`finalize`) or Cancel. A switch still connecting is cancelled; the current engine finishes.
    func shutdown(finalize: Bool) async {
        guard let controller else { return }
        await controller.shutdown(finalize: finalize)
    }

    /// True once a pick made the controller; Stop and Cancel then go through `shutdown`.
    var isActive: Bool { controller != nil }

    /// Today's stop result of the start session, once a pick ran it; nil when it never had one.
    func startResult() async -> RealtimeSessionStopResult? {
        await startStop?.value
    }

    /// The live text of each live span after the first, after `shutdown`.
    var laterSpanTexts: [Int: DictationSwitchPlan.SpanText] {
        sinks.mapValues(\.spanText)
    }
}

/// The session the recording started with, as the controller's first session.
@MainActor
private final class StartAdapter: MeetingEngineSession {
    private weak var owner: DictationEngineSwitcher?
    nonisolated let audioConsumer: @Sendable (Data) -> Void

    init(owner: DictationEngineSwitcher, consumer: @escaping @Sendable (Data) -> Void) {
        self.owner = owner
        audioConsumer = consumer
    }

    func start() async throws {} // Already connecting or connected on today's path.

    func finish(cap: Duration?) async -> Bool {
        await owner?.finishStart(cap: cap)
        return true
    }

    func cancel() async {
        await owner?.cancelStart()
    }
}
