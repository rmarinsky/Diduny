import Foundation

/// What a meeting's audio feeds (ADR-0013): a live engine, or nothing until Stop.
enum MeetingEngineTarget: Equatable {
    case live(EngineID)
    case afterStopOnly(EngineID)

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    var engine: EngineID {
        switch self {
        case let .live(engine), let .afterStopOnly(engine): engine
        }
    }

    var segment: MeetingSegment {
        switch self {
        case .afterStopOnly: .recordOnly
        case let .live(engine): engine == .didunyCloud || engine == .elevenLabs ? .cloud : .thisMac
        }
    }
}

enum SwitchFailure: Equatable {
    case noInternet, noModel(EngineID), noQuota, signedOut, needsKey, timedOut, other
}

/// One stretch of the recording on one target. Added only at a cut, so a failed or cancelled switch leaves no trace.
struct MeetingEngineSpan: Equatable {
    var target: MeetingEngineTarget
    var startFrame: Int
    var disrupted = false
    /// Frame of a terminal failure inside the span: from here on nothing was transcribed live.
    var failedAtFrame: Int?
}

struct MeetingEngineHistory: Equatable {
    var spans: [MeetingEngineSpan]
}

/// Where a click or a cut happened. Inputs, so the machine needs no audio or clock.
struct MeetingCutPoint: Equatable {
    var frame: Int
    var elapsed: TimeInterval
    /// Turns in the panel at that moment; a marker renders after them.
    var turns: Int
}

/// A panel-only line ("06:22 · switched to Cloud"). Never saved, never copied (D7).
struct MeetingSwitchMarker: Equatable {
    enum Kind: Equatable {
        case switched(from: MeetingEngineTarget, to: MeetingEngineTarget)
        case pair(String)
    }

    var kind: Kind
    var elapsed: TimeInterval
    var afterTurnCount: Int
    /// The time without live text that this marker opened; end nil while it is still open.
    var gapStart: TimeInterval?
    var gapEnd: TimeInterval?
}

enum MeetingPersistentNote: Equatable {
    case quotaMoved
    case offline
}

/// The switching rules of ADR-0013 D2. No AppKit, audio, clock or singletons.
struct MeetingSwitchMachine {
    enum Event: Equatable {
        /// `failure` is the pre-check result for a live target.
        case click(MeetingEngineTarget, failure: SwitchFailure?, at: MeetingCutPoint)
        /// Translate meeting's Between: a new session on the same engine.
        case restartLive(label: String, failure: SwitchFailure?)
        case sessionReady(id: UInt64, at: MeetingCutPoint)
        case sessionFailed(id: UInt64, SwitchFailure)
        case dropped(id: UInt64, terminal: Bool, frame: Int)
        case quotaExhausted(at: MeetingCutPoint)
        case wordsArrived
        /// The old engine's tail landed; the marker moves below it.
        case tailFinished(turns: Int)
        case end
    }

    enum Effect: Equatable {
        case startSession(id: UInt64, target: MeetingEngineTarget)
        case cancelSession(id: UInt64)
        case cutTo(id: UInt64)
        case stopCurrent
    }

    static let roundTripWindow: TimeInterval = 3

    /// What the panel highlights.
    private(set) var selected: MeetingEngineTarget
    /// What really receives audio.
    private(set) var running: MeetingEngineTarget
    /// The session feeding on now; nil on Record only.
    private(set) var runningID: UInt64?
    private(set) var markers: [MeetingSwitchMarker] = []
    private(set) var failure: SwitchFailure?
    private(set) var persistentNote: MeetingPersistentNote?
    private(set) var history: MeetingEngineHistory
    /// The engine that transcribes the whole recording after Stop.
    var afterStopEngine: EngineID
    private(set) var isEnded = false

    private struct Pending: Equatable {
        var id: UInt64
        var target: MeetingEngineTarget
        var pairLabel: String?
    }

    private var pending: Pending?
    private var nextID: UInt64
    private var wordsSinceLastMarker = false

    var isConnecting: Bool { pending != nil }
    var pendingID: UInt64? { pending?.id }

    /// `running` starts with session id 1 when live; nothing to connect first, as a meeting's Start does.
    init(start: MeetingEngineTarget, afterStopEngine: EngineID) {
        selected = start
        running = start
        self.afterStopEngine = afterStopEngine
        runningID = start.isLive ? 1 : nil
        nextID = 2
        history = MeetingEngineHistory(spans: [MeetingEngineSpan(target: start, startFrame: 0)])
        if case let .afterStopOnly(engine) = start { self.afterStopEngine = engine }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        guard !isEnded else { return [] }
        switch event {
        case let .click(target, failure, point):
            return click(target, failure: failure, at: point)
        case let .restartLive(label, failure):
            guard running.isLive, pending == nil else { return [] }
            if let failure {
                self.failure = failure
                return []
            }
            return beginSession(running, pairLabel: label)
        case let .sessionReady(id, point):
            guard let pending, pending.id == id else { return [] }
            self.pending = nil
            failure = nil
            persistentNote = nil
            addSpan(pending.target, frame: point.frame)
            addMarker(pending.pairLabel.map { .pair($0) } ?? .switched(from: running, to: pending.target), at: point)
            running = pending.target
            runningID = id
            selected = pending.target
            return [.cutTo(id: id)]
        case let .sessionFailed(id, reason):
            guard let pending, pending.id == id else { return [] }
            self.pending = nil
            selected = running
            failure = reason
            return []
        case let .dropped(id, terminal, frame):
            guard id == runningID, !history.spans.isEmpty else { return [] }
            let last = history.spans.count - 1
            history.spans[last].disrupted = true
            if terminal {
                if history.spans[last].failedAtFrame == nil { history.spans[last].failedAtFrame = frame }
                persistentNote = .offline
            }
            return []
        case let .quotaExhausted(point):
            return quotaExhausted(at: point)
        case .wordsArrived:
            wordsSinceLastMarker = true
            return []
        case let .tailFinished(turns):
            if let last = markers.indices.last { markers[last].afterTurnCount = max(markers[last].afterTurnCount, turns) }
            return []
        case .end:
            isEnded = true
            guard let pending else { return [] }
            self.pending = nil
            selected = running
            return [.cancelSession(id: pending.id)]
        }
    }

    // MARK: - Clicks

    private mutating func click(_ target: MeetingEngineTarget, failure newFailure: SwitchFailure?, at point: MeetingCutPoint) -> [Effect] {
        failure = nil
        if case let .afterStopOnly(engine) = target { afterStopEngine = engine }
        if target == selected, pending != nil || !target.isLive || target == running { return [] }

        var effects: [Effect] = []
        if let pending {
            effects.append(.cancelSession(id: pending.id))
            self.pending = nil
            selected = running
        }
        if target == running {
            // Back to where it was: a cancel with no span and no marker. Also a retry of nothing.
            return effects
        }
        if target.isLive {
            if let newFailure {
                failure = newFailure
                return effects
            }
            return effects + beginSession(target, pairLabel: nil)
        }
        // Record only: now, with no session.
        if !running.isLive {
            // Only the after-Stop engine changes: no session, no marker.
            running = target
            selected = target
            if let last = history.spans.indices.last { history.spans[last].target = target }
            return effects
        }
        return effects + cutToRecordOnly(target, at: point)
    }

    private mutating func beginSession(_ target: MeetingEngineTarget, pairLabel: String?) -> [Effect] {
        let id = nextID
        nextID += 1
        pending = Pending(id: id, target: target, pairLabel: pairLabel)
        selected = target
        return [.startSession(id: id, target: target)]
    }

    private mutating func cutToRecordOnly(_ target: MeetingEngineTarget, at point: MeetingCutPoint) -> [Effect] {
        addSpan(target, frame: point.frame)
        addMarker(.switched(from: running, to: target), at: point)
        running = target
        runningID = nil
        selected = target
        return [.stopCurrent]
    }

    private mutating func quotaExhausted(at point: MeetingCutPoint) -> [Effect] {
        var effects: [Effect] = []
        if let pending, pending.target.engine == .didunyCloud {
            effects.append(.cancelSession(id: pending.id))
            self.pending = nil
            selected = running
        }
        persistentNote = .quotaMoved
        // With a switch to another engine on its way, Diduny stops at that cut.
        guard running.engine == .didunyCloud, running.isLive, pending == nil else { return effects }
        return effects + cutToRecordOnly(.afterStopOnly(afterStopEngine), at: point)
    }

    // MARK: - History and markers

    private mutating func addSpan(_ target: MeetingEngineTarget, frame: Int) {
        history.spans.append(MeetingEngineSpan(target: target, startFrame: frame))
    }

    /// D7, with the prototype's reading: a live-to-live switch with no words since the last line replaces it; a
    /// return to where the last line came from within 3 s, with no words, leaves no line. Record only with no text
    /// yet has nothing to say.
    private mutating func addMarker(_ kind: MeetingSwitchMarker.Kind, at point: MeetingCutPoint) {
        defer { wordsSinceLastMarker = false }
        var kind = kind
        if case let .switched(from, to) = kind, !wordsSinceLastMarker, let last = markers.last,
           case let .switched(lastFrom, lastTo) = last.kind, lastTo == from
        {
            if to == lastFrom, point.elapsed - last.elapsed < Self.roundTripWindow {
                markers.removeLast()
                return
            }
            if from.isLive, to.isLive {
                kind = .switched(from: lastFrom, to: to)
                markers.removeLast()
            }
        }
        if case let .switched(from, to) = kind {
            if from.isLive, !to.isLive, point.turns == 0 { return }
            if !from.isLive, to.isLive { closeGap(at: point.elapsed) }
        }
        var marker = MeetingSwitchMarker(kind: kind, elapsed: point.elapsed, afterTurnCount: point.turns)
        if case let .switched(from, to) = kind, from.isLive, !to.isLive {
            marker.gapStart = point.elapsed
        }
        markers.append(marker)
    }

    private mutating func closeGap(at elapsed: TimeInterval) {
        guard let last = markers.indices.last, markers[last].gapStart != nil,
              markers[last].gapEnd == nil else { return }
        markers[last].gapEnd = elapsed
    }
}
