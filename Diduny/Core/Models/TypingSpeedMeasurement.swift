import Foundation

struct TypingSpeedMeasurement: Equatable {
    let grossWordsPerMinute: Double
    let netWordsPerMinute: Double
    let accuracy: Double
    let currentAccuracy: Double
    let processAccuracy: Double
    let completion: Double
    let elapsedSeconds: TimeInterval
    let correctionTimeSeconds: TimeInterval
    let typedCharacterCount: Int
    let correctCharacterCount: Int
    let targetCharacterCount: Int
    let totalInsertionCount: Int
    let incorrectInsertionCount: Int
    let correctionCount: Int
    let activeMistakeCount: Int

    static func evaluate(
        typedText: String,
        targetText: String,
        elapsedSeconds: TimeInterval,
        totalInsertionCount: Int? = nil,
        incorrectInsertionCount: Int? = nil,
        correctionCount: Int = 0,
        correctionTimeSeconds: TimeInterval = 0
    ) -> TypingSpeedMeasurement {
        let typed = Array(typedText)
        let target = Array(targetText)
        let safeElapsedSeconds = max(elapsedSeconds, 1)
        let minutes = safeElapsedSeconds / 60

        let correctCharacterCount = typed.enumerated().reduce(0) { count, pair in
            let index = pair.offset
            let character = pair.element
            guard target.indices.contains(index), target[index] == character else {
                return count
            }
            return count + 1
        }

        let activeMistakeCount = typed.enumerated().reduce(0) { count, pair in
            let index = pair.offset
            let character = pair.element
            guard target.indices.contains(index), target[index] == character else {
                return count + 1
            }
            return count
        }

        let safeTotalInsertionCount = max(totalInsertionCount ?? typed.count, typed.count)
        let safeIncorrectInsertionCount = min(
            max(incorrectInsertionCount ?? activeMistakeCount, 0),
            safeTotalInsertionCount
        )

        let currentAccuracy = typed.isEmpty ? 0 : Double(correctCharacterCount) / Double(typed.count)
        let processAccuracy = safeTotalInsertionCount == 0
            ? 0
            : Double(safeTotalInsertionCount - safeIncorrectInsertionCount) / Double(safeTotalInsertionCount)
        let accuracy = typed.isEmpty ? 0 : min(currentAccuracy, processAccuracy)
        let completion = target.isEmpty ? 0 : min(Double(typed.count) / Double(target.count), 1)
        let grossWPM = (Double(typed.count) / 5) / minutes
        let netWPM = grossWPM * accuracy

        return TypingSpeedMeasurement(
            grossWordsPerMinute: grossWPM,
            netWordsPerMinute: netWPM,
            accuracy: accuracy,
            currentAccuracy: currentAccuracy,
            processAccuracy: processAccuracy,
            completion: completion,
            elapsedSeconds: safeElapsedSeconds,
            correctionTimeSeconds: max(correctionTimeSeconds, 0),
            typedCharacterCount: typed.count,
            correctCharacterCount: correctCharacterCount,
            targetCharacterCount: target.count,
            totalInsertionCount: safeTotalInsertionCount,
            incorrectInsertionCount: safeIncorrectInsertionCount,
            correctionCount: max(correctionCount, 0),
            activeMistakeCount: activeMistakeCount
        )
    }
}
