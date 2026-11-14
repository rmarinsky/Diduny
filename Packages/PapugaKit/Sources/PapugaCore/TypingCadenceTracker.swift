import Foundation

/// Live estimate of the user's typing cadence — the smoothed gap between
/// printable keystrokes — so AutoFix deadlines scale to the person at the
/// keyboard instead of one fixed constant. Fixed timers fail both ways: a fast
/// typist is three words past the mistake before a 0.6 s idle timer fires, and
/// a slow typist gets a proposal shoved at them in the middle of a phrase they
/// are still composing.
struct TypingCadenceTracker: Equatable {
    /// Gaps above this are pauses (thinking, reading, switching windows), not
    /// typing rhythm — they would drag the average toward "everyone is slow".
    static let pauseCutoff: TimeInterval = 2.0
    /// EMA weight of the newest gap — roughly a 30-keystroke memory: long
    /// enough to be stable, short enough to adapt within one paragraph.
    static let smoothing = 0.1
    /// Physically plausible per-keystroke gaps (≈160 WPM burst … hunt-and-peck).
    static let gapRange: ClosedRange<TimeInterval> = 0.04...0.8
    /// Gap assumed before anything is known — a middling ~65 WPM typist.
    static let defaultGap: TimeInterval = 0.18

    private(set) var averageGap: TimeInterval
    private var lastKeystroke: TimeInterval?

    init(averageGap: TimeInterval = 0) {
        self.averageGap = averageGap > 0
            ? averageGap.clampedToGapRange
            : Self.defaultGap
    }

    /// Seed from the typing-test screen's measurement when no live average has
    /// been accumulated yet. 1 word = 5 characters, the same convention the
    /// test uses to compute WPM in the first place.
    static func seededGap(wordsPerMinute: Double) -> TimeInterval {
        guard wordsPerMinute > 0 else { return defaultGap }
        return (60.0 / (wordsPerMinute * 5)).clampedToGapRange
    }

    mutating func notePrintable(at timestamp: TimeInterval) {
        defer { lastKeystroke = timestamp }
        guard let last = lastKeystroke else { return }
        let gap = timestamp - last
        guard gap > 0, gap < Self.pauseCutoff else { return }
        averageGap += Self.smoothing * (gap.clampedToGapRange - averageGap)
    }

    /// The gap across a focus or app change is not typing rhythm.
    mutating func noteInterruption() {
        lastKeystroke = nil
    }

    // MARK: - Derived deadlines

    /// How long a run waits for the next word before it is judged.
    var commitPause: TimeInterval { clamped(averageGap * 4, 0.45, 1.5) }

    /// Grace before a lone word's fix is applied — the window in which
    /// continued typing folds it into a run instead.
    var singleWordGrace: TimeInterval { clamped(averageGap * 2, 0.2, 0.6) }

    /// How long the proposal panel stays up once the user has actually paused.
    var proposalDuration: TimeInterval { clamped(averageGap * 25, 4, 8) }

    /// How long a deferred chip survives while the user keeps typing — scaled
    /// so it covers roughly the same *amount of typing* for everyone (about a
    /// sentence), which means more wall-clock for a slower typist.
    var chipTimeToLive: TimeInterval { clamped(averageGap * 60, 8, 15) }

    private func clamped(_ value: TimeInterval, _ low: TimeInterval, _ high: TimeInterval) -> TimeInterval {
        min(max(value, low), high)
    }
}

private extension TimeInterval {
    var clampedToGapRange: TimeInterval {
        min(max(self, TypingCadenceTracker.gapRange.lowerBound), TypingCadenceTracker.gapRange.upperBound)
    }
}
