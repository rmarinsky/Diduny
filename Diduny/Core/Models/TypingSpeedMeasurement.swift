import Foundation

struct TypingSpeedMeasurement: Equatable {
    let grossWordsPerMinute: Double
    let netWordsPerMinute: Double
    let accuracy: Double
    let completion: Double
    let elapsedSeconds: TimeInterval
    let typedCharacterCount: Int
    let correctCharacterCount: Int
    let targetCharacterCount: Int

    static func evaluate(
        typedText: String,
        targetText: String,
        elapsedSeconds: TimeInterval
    ) -> TypingSpeedMeasurement {
        let typed = Array(typedText)
        let target = Array(targetText)
        let safeElapsedSeconds = max(elapsedSeconds, 1)
        let minutes = safeElapsedSeconds / 60

        let correctCharacterCount = zip(typed, target).reduce(0) { count, pair in
            pair.0 == pair.1 ? count + 1 : count
        }

        let accuracy = typed.isEmpty ? 0 : Double(correctCharacterCount) / Double(typed.count)
        let completion = target.isEmpty ? 0 : min(Double(typed.count) / Double(target.count), 1)
        let grossWPM = (Double(typed.count) / 5) / minutes
        let netWPM = grossWPM * accuracy

        return TypingSpeedMeasurement(
            grossWordsPerMinute: grossWPM,
            netWordsPerMinute: netWPM,
            accuracy: accuracy,
            completion: completion,
            elapsedSeconds: safeElapsedSeconds,
            typedCharacterCount: typed.count,
            correctCharacterCount: correctCharacterCount,
            targetCharacterCount: target.count
        )
    }
}
