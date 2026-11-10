import Foundation

/// What a session reports. The controller drops anything from a session that is no longer current (C5).
struct MeetingSessionCallbacks {
    var tokens: @MainActor @Sendable ([CoalescedTranscriptEvent]) -> Void
    var status: @MainActor @Sendable (RealtimeConnectionStatus) -> Void
    var error: @MainActor @Sendable (Error) -> Void
}

/// One live engine for one stretch of a meeting (ADR-0013 D1). Each has its own service instance.
@MainActor
protocol MeetingEngineSession: AnyObject {
    /// Fed by the fan-out on the audio queue, only while this session is current.
    nonisolated var audioConsumer: @Sendable (Data) -> Void { get }
    /// Connects or loads; returns when the engine can take audio.
    func start() async throws
    /// Finishes the tail, capped when `cap` is set, then disconnects. True when the engine confirmed the end.
    func finish(cap: Duration?) async -> Bool
    /// Disconnects at once and drops every callback.
    func cancel() async
}

/// Runs `MeetingSwitchMachine` against real sessions: one per target, the fan-out, the tail hand-over.
/// One per recording, on the main actor. Everything it does not own (capture, the file) a switch never touches.
@MainActor
final class MeetingEngineController {
    struct Environment {
        var readFrame: () -> Int
        var elapsed: () -> TimeInterval
        var turns: () -> Int
        var finalText: () -> String
        /// The pre-check; nil when the target may connect.
        var readiness: (MeetingEngineTarget) -> SwitchFailure?
        var makeSession: (MeetingEngineTarget, MeetingSessionCallbacks) -> MeetingEngineSession?
        var applyTokens: ([CoalescedTranscriptEvent]) -> Void
        var applyStatus: (RealtimeConnectionStatus) -> Void
        var applyError: (Error) -> Void
        /// The old engine's tail is in; closes its provisional text and turn.
        var closeTurn: () -> Void
        /// A live session became current, or the meeting went to Record only.
        var didCut: (MeetingEngineTarget) -> Void
        /// A new pair is now live.
        var commitPair: (TranslationLanguagePair) -> Void = { _ in }
        /// Panel state changed.
        var didChange: (MeetingSwitchMachine) -> Void
    }

    static let tailCap: Duration = .seconds(2)

    static func connectBudget(_ target: MeetingEngineTarget) -> Duration {
        target.engine == .whisper ? .seconds(45) : .seconds(15)
    }

    let fanOut: MeetingAudioFanOut
    private(set) var machine: MeetingSwitchMachine
    private let env: Environment
    private var sessions: [UInt64: MeetingEngineSession] = [:]
    private var connectTasks: [UInt64: Task<Void, Never>] = [:]
    /// Sessions in text order: the head writes, the others wait so a tail lands above the marker.
    private var textOrder: [UInt64] = []
    private var heldEvents: [UInt64: [[CoalescedTranscriptEvent]]] = [:]
    private var tail: Task<Void, Never>?
    private var spanOfSession: [UInt64: Int] = [:]
    /// Live text per span, snapshotted when its session has finished (D4).
    private(set) var liveTexts: [Int: String] = [:]
    private var snapshotLength = 0
    private var lastFinishConfirmed = true
    private var isShutDown = false
    /// The pair a restarting session connects with; read by the session factory.
    private(set) var pendingPair: TranslationLanguagePair?

    init(start: MeetingEngineTarget, afterStopEngine: EngineID, fanOut: MeetingAudioFanOut = MeetingAudioFanOut(), environment: Environment) {
        machine = MeetingSwitchMachine(start: start, afterStopEngine: afterStopEngine)
        self.fanOut = fanOut
        env = environment
    }

    /// The first engine: fed from now on and connecting in the background, because a recording never waits for
    /// the network (the service buffers until its socket is up). Returns when the connect has finished only with `wait`.
    func startInitial(wait: Bool = false) async {
        let task = beginInitial()
        if wait { await task?.value }
    }

    /// `startInitial` without waiting, callable where no `await` is possible (a dictation's first pick).
    @discardableResult
    func beginInitial() -> Task<Void, Never>? {
        guard let id = machine.runningID else { return nil }
        guard let session = env.makeSession(machine.running, callbacks(for: id)) else {
            markFailedRunning(id)
            return nil
        }
        sessions[id] = session
        spanOfSession[id] = 0
        textOrder = [id]
        fanOut.setConsumer(session.audioConsumer)
        // Holds the session: a connect returning after Stop must still be able to close what it opened.
        let task = Task { [weak self, session] in
            do {
                try await session.start()
                if self?.sessions[id] == nil { await session.cancel() }
                self?.initialConnectFinished(id)
            } catch {
                self?.initialConnectFailed(id, error)
            }
        }
        connectTasks[id] = task
        return task
    }

    // MARK: - Input

    func click(_ target: MeetingEngineTarget) {
        guard !isShutDown else { return }
        pendingPair = nil
        let failure = target.isLive ? env.readiness(target) : nil
        send(.click(target, failure: failure, at: cutPoint()))
    }

    /// Translate meeting's Between. The pair counts only from the cut; a failure or a newer click drops it.
    func restartLive(pair: TranslationLanguagePair) {
        guard !isShutDown, machine.running.isLive, !machine.isConnecting else { return }
        pendingPair = pair
        send(.restartLive(label: pair.shortLabel, failure: env.readiness(machine.running)))
    }

    /// `usageLimitExceeded` on connect or reconnect (D2 trigger 1). The client deadline, trigger 2, is deliberately
    /// not armed: it would end live text where today the socket continues, and that is Roman's call.
    func quotaExhausted() {
        guard !isShutDown else { return }
        send(.quotaExhausted(at: cutPoint()))
    }

    /// Stop: cancels a pending switch, lets the tails land, then finishes the current engine.
    @discardableResult
    func shutdown(finalize: Bool) async -> Bool {
        guard !isShutDown else { return lastFinishConfirmed }
        let endEffects = machine.handle(.end)
        endEffects.forEach(run)
        env.didChange(machine)
        guard finalize else {
            await cancelEverything()
            return true
        }
        isShutDown = true
        await tail?.value
        tail = nil
        var confirmed = true
        if let id = machine.runningID, let session = sessions[id] {
            confirmed = await session.finish(cap: nil)
            connectTasks[id]?.cancel()
            sessions[id] = nil
            snapshot(session: id)
        }
        fanOut.setConsumer(nil)
        return confirmed
    }

    /// Sleep, capture error, Cancel: no tail, nothing may write status or text from here on.
    private func cancelEverything() async {
        isShutDown = true
        fanOut.setConsumer(nil)
        connectTasks.values.forEach { $0.cancel() }
        connectTasks = [:]
        tail?.cancel()
        tail = nil
        let open = Array(sessions.values)
        sessions = [:]
        textOrder = []
        heldEvents = [:]
        for session in open {
            await session.cancel()
        }
    }

    // MARK: - Machine

    private func cutPoint() -> MeetingCutPoint {
        MeetingCutPoint(frame: env.readFrame(), elapsed: env.elapsed(), turns: env.turns())
    }

    private func send(_ event: MeetingSwitchMachine.Event) {
        let before = machine.runningID
        let effects = machine.handle(event)
        for effect in effects {
            switch effect {
            case .stopCurrent:
                retire(before)
                env.applyStatus(.disconnected)
                env.didCut(machine.running)
            case .cutTo:
                retire(before)
                if let pendingPair { env.commitPair(pendingPair) }
                env.applyStatus(.connected)
                env.didCut(machine.running)
            default:
                run(effect)
            }
        }
        if !machine.isConnecting { pendingPair = nil }
        env.didChange(machine)
    }

    private func run(_ effect: MeetingSwitchMachine.Effect) {
        switch effect {
        case let .startSession(id, target):
            startSwitch(id: id, target: target)
        case let .cancelSession(id):
            cancelPending(id)
        case .cutTo, .stopCurrent:
            break // Handled in `send`, which knows the old session.
        }
    }

    private func startSwitch(id: UInt64, target: MeetingEngineTarget) {
        guard let session = env.makeSession(target, callbacks(for: id)) else {
            send(.sessionFailed(id: id, .other))
            return
        }
        sessions[id] = session
        let budget = Self.connectBudget(target)
        connectTasks[id] = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor [weak self, session] in
                    do {
                        try await session.start()
                        // Stale, or the controller is gone: this session disconnects itself.
                        guard let self, machine.pendingID == id, sessions[id] === session else {
                            await session.cancel()
                            return
                        }
                        sessionReady(id)
                    } catch {
                        self?.sessionFailed(id, error)
                    }
                }
                group.addTask { @MainActor [weak self] in
                    try? await Task.sleep(for: budget)
                    guard !Task.isCancelled else { return }
                    self?.sessionTimedOut(id)
                }
                await group.next()
                group.cancelAll()
            }
        }
    }

    /// The cut: frame and consumer in one lock section. A stale session disconnects itself.
    private func sessionReady(_ id: UInt64) {
        guard machine.pendingID == id, let session = sessions[id], !isShutDown else { return }
        let frame = fanOut.setConsumer(session.audioConsumer, readFrame: env.readFrame)
        textOrder.append(id)
        spanOfSession[id] = machine.history.spans.count
        send(.sessionReady(id: id, at: MeetingCutPoint(frame: frame, elapsed: env.elapsed(), turns: env.turns())))
    }

    private func sessionFailed(_ id: UInt64, _ error: Error) {
        guard machine.pendingID == id else { return }
        cancelSessionObject(id)
        send(.sessionFailed(id: id, Self.failure(from: error, target: machine.selected)))
    }

    private func sessionTimedOut(_ id: UInt64) {
        guard machine.pendingID == id else { return }
        cancelSessionObject(id)
        send(.sessionFailed(id: id, .timedOut))
    }

    private func cancelPending(_ id: UInt64) {
        cancelSessionObject(id)
    }

    private func cancelSessionObject(_ id: UInt64) {
        connectTasks.removeValue(forKey: id)?.cancel()
        let session = sessions.removeValue(forKey: id)
        Task { await session?.cancel() }
    }

    /// The old engine finishes in the background, capped; new text waits until its tail is in.
    private func retire(_ id: UInt64?) {
        if machine.running.isLive == false {
            fanOut.setConsumer(nil)
        }
        guard let id, let session = sessions[id] else { return }
        connectTasks.removeValue(forKey: id)?.cancel()
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            _ = await session.finish(cap: Self.tailCap)
            self?.tailFinished(id)
        }
    }

    private func tailFinished(_ id: UInt64) {
        guard !isShutDown || sessions[id] != nil else { return }
        sessions[id] = nil
        env.closeTurn()
        snapshot(session: id)
        _ = machine.handle(.tailFinished(turns: env.turns()))
        textOrder.removeAll { $0 == id }
        if let head = textOrder.first, let held = heldEvents.removeValue(forKey: head) {
            held.forEach(apply)
        }
        env.didChange(machine)
    }

    private func snapshot(session id: UInt64) {
        guard let span = spanOfSession[id] else { return }
        let text = env.finalText()
        let added = String(text.dropFirst(snapshotLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        snapshotLength = text.count
        if !added.isEmpty { liveTexts[span] = added }
    }

    // MARK: - Initial session

    private func initialConnectFinished(_ id: UInt64) {
        connectTasks[id] = nil
    }

    private func initialConnectFailed(_ id: UInt64, _ error: Error) {
        connectTasks[id] = nil
        guard !isShutDown, !Task.isCancelled, machine.runningID == id else { return }
        env.applyError(error)
        if case .usageLimitExceeded = error as? RealtimeTranscriptionError {
            quotaExhausted()
            return
        }
        markFailedRunning(id)
        env.applyStatus(.failed(error.localizedDescription))
    }

    private func markFailedRunning(_ id: UInt64) {
        send(.dropped(id: id, terminal: true, frame: env.readFrame()))
    }

    // MARK: - Session callbacks

    private func callbacks(for id: UInt64) -> MeetingSessionCallbacks {
        MeetingSessionCallbacks(
            tokens: { [weak self] events in self?.receive(events, from: id) },
            status: { [weak self] status in self?.receive(status, from: id) },
            error: { [weak self] error in self?.receive(error, from: id) }
        )
    }

    private func receive(_ events: [CoalescedTranscriptEvent], from id: UInt64) {
        guard sessions[id] != nil, textOrder.contains(id) else { return } // Stale or still connecting.
        if textOrder.first == id {
            apply(events)
        } else {
            heldEvents[id, default: []].append(events)
        }
    }

    private func apply(_ events: [CoalescedTranscriptEvent]) {
        env.applyTokens(events)
        let hasWords = events.contains { event in
            if case let .tokens(tokens) = event { return tokens.contains { !$0.text.isEmpty } }
            return false
        }
        if hasWords { _ = machine.handle(.wordsArrived) }
    }

    private func receive(_ status: RealtimeConnectionStatus, from id: UInt64) {
        guard machine.runningID == id, sessions[id] != nil else { return }
        env.applyStatus(status)
        if let terminal = Self.dropSignal(status, engine: machine.running.engine) {
            send(.dropped(id: id, terminal: terminal, frame: env.readFrame()))
        }
    }

    private func receive(_ error: Error, from id: UInt64) {
        guard machine.runningID == id else { return }
        env.applyError(error)
        if case .usageLimitExceeded = error as? RealtimeTranscriptionError { quotaExhausted() }
    }

    // MARK: - Rules

    /// D2: any Diduny reconnect or failure can lose audio, so the span is disrupted. ElevenLabs reconnects as its
    /// normal rotation (C21), so only a failure counts. Nil: not a drop. The value says whether it is terminal.
    nonisolated static func dropSignal(_ status: RealtimeConnectionStatus, engine: EngineID) -> Bool? {
        switch status {
        case .failed: true
        case .reconnecting: engine == .elevenLabs ? nil : false
        case .disconnected: engine == .didunyCloud ? false : nil
        case .connected, .connecting: nil
        }
    }

    nonisolated static func failure(from error: Error, target: MeetingEngineTarget) -> SwitchFailure {
        if case .usageLimitExceeded = error as? RealtimeTranscriptionError { return .noQuota }
        if error is ElevenLabsError { return .needsKey }
        if target.engine == .whisper { return .noModel(.whisper) }
        if (error as? URLError) != nil { return .noInternet }
        if case .connectionFailed = error as? RealtimeTranscriptionError { return .noInternet }
        return .other
    }

    /// Readiness to the failure line. `.notDownloaded` on Parakeet is not a failure (it is never live anyway).
    nonisolated static func failure(from readiness: EngineReadiness, engine: EngineID) -> SwitchFailure? {
        switch readiness {
        case .ready: nil
        case .notDownloaded: .noModel(engine)
        case .noQuota: .noQuota
        case .signedOut: .signedOut
        case .needsKey: .needsKey
        case .unsupportedHardware, .unavailable: .other
        }
    }
}
