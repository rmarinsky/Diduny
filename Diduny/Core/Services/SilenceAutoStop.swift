import Foundation

/// Hysteresis over per-frame speech probabilities from a VAD model:
/// becomes speech above `onThreshold`, returns to silence only below
/// `offThreshold`, so values hovering around one threshold don't flicker.
struct SpeechProbabilityGate {
    let onThreshold: Float
    let offThreshold: Float
    private(set) var isSpeech = false

    /// Silero reference values: 0.5 on, 0.35 off (a 0.15 gap).
    init(onThreshold: Float = 0.5, offThreshold: Float = 0.35) {
        self.onThreshold = onThreshold
        self.offThreshold = offThreshold
    }

    mutating func update(probability: Float) -> Bool {
        if isSpeech {
            if probability < offThreshold { isSpeech = false }
        } else if probability > onThreshold {
            isSpeech = true
        }
        return isSpeech
    }
}

/// Decides when a recording should stop after silence. The timer starts only
/// after the first speech, any speech resets it, the last
/// `countdownWindow` seconds are reported as a countdown, and `.stop` is
/// reported once.
struct SilenceAutoStopTimer {
    enum Decision: Equatable {
        case keepRecording
        case countdown(secondsLeft: Int)
        case stop
    }

    static let countdownWindow: TimeInterval = 3

    let timeout: TimeInterval
    private var lastSpeechAt: Date?
    private var didStop = false

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    mutating func update(isSpeech: Bool, at now: Date) -> Decision {
        guard !didStop else { return .keepRecording }

        if isSpeech {
            lastSpeechAt = now
            return .keepRecording
        }
        guard let lastSpeechAt else { return .keepRecording }

        let remaining = timeout - now.timeIntervalSince(lastSpeechAt)
        if remaining <= 0 {
            didStop = true
            return .stop
        }
        if remaining <= min(Self.countdownWindow, timeout) {
            return .countdown(secondsLeft: Int(remaining.rounded(.up)))
        }
        return .keepRecording
    }
}
