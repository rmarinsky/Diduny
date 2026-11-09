import Foundation
import Observation

/// What the command panel shows after Stop (design-spec 7.7, changes/02 section 8).
struct EdgeCommandOutcome: Equatable, Identifiable {
    enum Flow: Equatable {
        case dictation
        /// `languageName`: the Translate into language, for example "English".
        case dictationTranslation(languageName: String)
        case meeting
        /// `pair`: the saved pair in codes, for example "EN ↔ UK".
        case meetingTranslation(pair: String)

        var isMeeting: Bool {
            switch self {
            case .meeting, .meetingTranslation: true
            case .dictation, .dictationTranslation: false
            }
        }
    }

    /// Where the text went (default 8, risk in WP-42).
    enum Delivery: Equatable {
        /// Auto-paste posted ⌘V.
        case pasted
        /// Auto-paste off or the paste failed: the text is only on the clipboard.
        case copied
    }

    /// New per outcome, so the check pulse (M8) and the M1 swap run once for each.
    let id = UUID()
    let flow: Flow
    /// Recorded length, whole seconds.
    let durationSeconds: Int
    var delivery: Delivery = .copied
    /// Dictation: the final text for the result box.
    var resultText: String = ""
    /// Meetings: the library recording, for Open recording.
    var recordingID: UUID?
    /// Dictation with nothing more to say than "done": the header and its logo only, no result or Copy.
    var headerOnly = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.flow == rhs.flow && lhs.durationSeconds == rhs.durationSeconds
            && lhs.delivery == rhs.delivery && lhs.resultText == rhs.resultText && lhs.recordingID == rhs.recordingID
            && lhs.headerOnly == rhs.headerOnly
    }

    var title: String {
        switch (flow, delivery) {
        case (.dictation, .pasted): String(localized: "Dictated and pasted")
        case (.dictationTranslation, .pasted): String(localized: "Translated and pasted")
        case (.meeting, .pasted), (.meetingTranslation, .pasted): String(localized: "Meeting ended and pasted")
        case (.meeting, .copied), (.meetingTranslation, .copied): String(localized: "Meeting saved")
        case (.dictation, .copied), (.dictationTranslation, .copied): String(localized: "Copied")
        }
    }

    func subtitle(transcript: OutcomeTranscriptState) -> String {
        switch flow {
        case .dictation:
            return String(format: String(localized: "%lld s · also in Recordings"), durationSeconds)
        case let .dictationTranslation(languageName):
            return String(format: String(localized: "Translated into %@ · %lld s"), languageName, durationSeconds)
        case .meeting, .meetingTranslation:
            let duration = Self.meetingDuration(durationSeconds)
            guard transcript == .ready else {
                return String(format: String(localized: "%@ · making the transcript..."), duration)
            }
            if case let .meetingTranslation(pair) = flow {
                return String(format: String(localized: "%@ · transcript ready, translated %@"), duration, pair)
            }
            return String(format: String(localized: "%@ · transcript ready"), duration)
        }
    }

    /// "6 min 22 s"; under a minute "42 s".
    static func meetingDuration(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        if seconds < 60 { return String(format: String(localized: "%lld s"), seconds) }
        return String(format: String(localized: "%lld min %lld s"), seconds / 60, seconds % 60)
    }
}

/// The meeting transcript after Stop, derived from the queue each time the view draws.
enum OutcomeTranscriptState: Equatable {
    /// Queued or running; `fraction` is the queue's current-stage fraction for this recording.
    case making(fraction: Double)
    case ready

    /// Default 02 Q12: nothing queued for this recording means the transcript is ready at once
    /// (a live meeting returns its text at Stop). Another recording's progress never shows.
    static func make(
        recordingID: UUID?,
        isQueued: Bool,
        currentRecordingID: UUID?,
        currentProgress: QueueProgress?
    ) -> OutcomeTranscriptState {
        guard let recordingID else { return .ready }
        if currentRecordingID == recordingID {
            return .making(fraction: currentProgress?.fraction ?? 0)
        }
        return isQueued ? .making(fraction: 0) : .ready
    }
}

/// Default 02 Q13: dictation has no fraction after Stop, so the bar fills linearly over 1.4 s
/// and jumps to full when the text arrives. For the progress row (WP-40 / WP-30).
enum StopProgressTiming {
    static let dictationFill: TimeInterval = 1.4

    static func dictationFraction(elapsed: TimeInterval, textArrived: Bool) -> Double {
        if textArrived { return 1 }
        return min(max(elapsed / dictationFill, 0), 1)
    }
}

/// Holds the outcome of the last recording on the Floating surface until the panel closes,
/// New recording, or the next recording starts.
@Observable
@MainActor
final class EdgeCommandOutcomeStore {
    private(set) var outcome: EdgeCommandOutcome?

    func show(_ outcome: EdgeCommandOutcome) {
        self.outcome = outcome
    }

    func clear() {
        outcome = nil
    }
}

/// When the command panel shows the outcome instead of the live view (WP-42): the live
/// presentation is up, the recording reached success, and an outcome is held.
enum EdgeCommandOutcomeVisibility {
    static func outcome(
        _ outcome: EdgeCommandOutcome?,
        isShowingLiveFeedback: Bool,
        phase: LiveDictationOverlayPhase
    ) -> EdgeCommandOutcome? {
        guard isShowingLiveFeedback, phase == .pasted else { return nil }
        return outcome
    }
}
