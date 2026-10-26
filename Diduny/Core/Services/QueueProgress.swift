import Foundation

/// Stage and progress of the recording the queue is working on, shown in the
/// Recordings row and detail view. Fraction and time left describe the current
/// stage, not the whole pipeline.
struct QueueProgress: Equatable {
    enum Stage: String, Equatable {
        case queued
        case preparing
        case uploading
        case transcribing
        case finishing

        /// Pipeline order: preparing → uploading → transcribing → finishing.
        var order: Int {
            switch self {
            case .queued: 0
            case .preparing: 1
            case .uploading: 2
            case .transcribing: 3
            case .finishing: 4
            }
        }
    }

    var stage: Stage
    var provider: TranscriptionProvider
    var totalSeconds: TimeInterval
    var fraction: Double?
    var processedSeconds: TimeInterval?
    var secondsLeft: TimeInterval?

    /// Cloud transcription has no server progress; its values are estimated.
    var isEstimate: Bool {
        stage == .transcribing && provider == .cloud
    }
}

enum QueueProgressFormatter {
    /// Row preview line, e.g. "Transcribing · ≈ 11 of 18 min · 62%".
    static func rowLine(_ progress: QueueProgress) -> String {
        var parts = [detailLine(progress)]
        if progress.stage == .uploading || progress.stage == .transcribing, let percent = percent(progress) {
            parts.append(String(localized: "\(percent)%"))
        }
        return parts.joined(separator: " · ")
    }

    /// Detail view line: the row line without the trailing percent.
    static func detailLine(_ progress: QueueProgress) -> String {
        let name = stageName(progress.stage)
        guard progress.stage == .transcribing, let amount = amount(progress) else { return name }
        return "\(name) · \(amount)"
    }

    /// "~N min left" / "~N s left"; nil when unknown or the stage has no estimate.
    static func timeLeft(_ progress: QueueProgress) -> String? {
        guard progress.stage == .transcribing, let secondsLeft = progress.secondsLeft, secondsLeft > 0 else {
            return nil
        }
        if secondsLeft >= 60 {
            let minutes = Int((secondsLeft / 60).rounded(.up))
            return String(localized: "~\(minutes) min left")
        }
        let seconds = max(5, Int((secondsLeft / 5).rounded(.up)) * 5)
        return String(localized: "~\(seconds) s left")
    }

    /// Value for the progress bar; Cloud estimates never pass 95%.
    static func barFraction(_ progress: QueueProgress) -> Double? {
        guard let fraction = progress.fraction else { return nil }
        let capped = progress.isEstimate ? min(fraction, CloudTranscriptionEstimate.maxFraction) : fraction
        return max(0, min(capped, 1))
    }

    /// Whole percent, rounded down; Cloud estimates never pass 95%.
    static func percent(_ progress: QueueProgress) -> Int? {
        barFraction(progress).map { Int(($0 * 100).rounded(.down)) }
    }

    static func stageName(_ stage: QueueProgress.Stage) -> String {
        switch stage {
        case .queued: String(localized: "Queued")
        case .preparing: String(localized: "Preparing audio")
        case .uploading: String(localized: "Uploading")
        case .transcribing: String(localized: "Transcribing")
        case .finishing: String(localized: "Finishing")
        }
    }

    private static func amount(_ progress: QueueProgress) -> String? {
        guard let processed = progress.processedSeconds else { return nil }
        let total = progress.totalSeconds
        let estimate = progress.isEstimate
        if total < 120 {
            let done = Int(min(processed, total).rounded(.down))
            let all = max(1, Int(total.rounded()))
            return estimate
                ? String(localized: "≈ \(done) of \(all) s")
                : String(localized: "\(done) of \(all) s")
        }
        let done = Int((min(processed, total) / 60).rounded(.down))
        let all = max(1, Int((total / 60).rounded()))
        return estimate
            ? String(localized: "≈ \(done) of \(all) min")
            : String(localized: "\(done) of \(all) min")
    }
}

/// Time-based estimate for Cloud transcription, which reports no progress.
struct CloudTranscriptionEstimate {
    static let maxFraction = 0.95
    // Q3 of the spec: replace with the median from recent completed jobs. Not measured yet.
    static let fixedOverheadSeconds: TimeInterval = 20
    static let serverSecondsPerAudioSecond: TimeInterval = 0.1

    let audioSeconds: TimeInterval
    let startedAt: Date

    var expectedSeconds: TimeInterval {
        Self.fixedOverheadSeconds + audioSeconds * Self.serverSecondsPerAudioSecond
    }

    /// Rises with elapsed time and stops at 95% until the job reports completion.
    func fraction(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        return min(Self.maxFraction, elapsed / expectedSeconds)
    }

    /// Nil once the job runs longer than expected: the estimate no longer knows.
    func secondsLeft(at date: Date) -> TimeInterval? {
        let left = expectedSeconds - max(0, date.timeIntervalSince(startedAt))
        return left > 0 ? left : nil
    }
}
