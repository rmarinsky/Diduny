import Foundation

/// The parts of Papuga's `Utilities/Constants.swift` the engine layer uses. The time-saved
/// functions take the measured typing speed as a parameter instead of reading
/// the Papuga setting `measuredTypingWPM` (Papuga default: 0 = not measured).
enum Constants {
    static let bundleIdentifier = "ua.com.rmarinsky.papuga"
    static let maxKeyCode: UInt16 = 127

    /// Fixed cost of a manual fix independent of length: notice the mistake +
    /// select the text + trigger the correction.
    static let manualFixOverheadSeconds: Double = 2.0
    /// Fallback typing speed when the user hasn't run the typing-speed test.
    static let defaultTypingWordsPerMinute: Double = 40
    static let typingWordsPerMinuteRange: ClosedRange<Double> = 10...160

    static func sanitizedTypingWordsPerMinute(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTypingWordsPerMinute }
        return min(max(value, typingWordsPerMinuteRange.lowerBound), typingWordsPerMinuteRange.upperBound).rounded()
    }

    /// The typing speed feeding the estimate: the user's measured value if the
    /// test has been taken, else the default.
    static func effectiveTypingWordsPerMinute(measuredTypingWPM measured: Double = 0) -> Double {
        return measured > 0 ? sanitizedTypingWordsPerMinute(measured) : defaultTypingWordsPerMinute
    }

    private static func secondsPerWord(measuredTypingWPM: Double) -> Double {
        60.0 / max(effectiveTypingWordsPerMinute(measuredTypingWPM: measuredTypingWPM), 1)
    }

    /// Estimated seconds saved by one replacement of `words` words.
    static func secondsSaved(words: Int, measuredTypingWPM: Double = 0) -> Int {
        let count = Double(max(1, words))
        return Int((manualFixOverheadSeconds + count * secondsPerWord(measuredTypingWPM: measuredTypingWPM)).rounded())
    }

    /// Aggregate estimate across many replacements: per-replacement overhead
    /// plus per-word retype cost. Matches `secondsSaved(words:)` summed over
    /// `replacementCount` replacements totalling `totalWords` words.
    static func estimatedSecondsSaved(replacementCount: Int, totalWords: Int, measuredTypingWPM: Double = 0) -> Int {
        guard replacementCount > 0 else { return 0 }
        let estimated = Double(replacementCount) * manualFixOverheadSeconds
            + Double(totalWords) * secondsPerWord(measuredTypingWPM: measuredTypingWPM)
        return Int(estimated.rounded())
    }
}
