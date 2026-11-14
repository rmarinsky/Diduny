import Foundation

struct TypingSpeedMetrics: Equatable {
    let typedCharacters: Int
    let correctCharacters: Int
    let errorCharacters: Int
    let elapsedSeconds: TimeInterval
    let progress: Double
    let accuracy: Double
    let wordsPerMinute: Double
    let charactersPerMinute: Double
    let isComplete: Bool
}

enum TypingSpeedTestEngine {
    static func metrics(
        prompt: String,
        typedText: String,
        elapsedSeconds: TimeInterval
    ) -> TypingSpeedMetrics {
        let promptCharacters = Array(prompt)
        let typedCharacters = Array(typedText)
        let typedCount = typedCharacters.count
        let promptCount = promptCharacters.count

        var correctCount = 0
        var errorCount = 0

        for index in typedCharacters.indices {
            guard index < promptCharacters.count else {
                errorCount += 1
                continue
            }

            if typedCharacters[index] == promptCharacters[index] {
                correctCount += 1
            } else {
                errorCount += 1
            }
        }

        let safeElapsedSeconds = max(0, elapsedSeconds)
        let minutes = safeElapsedSeconds / 60
        let accuracy = typedCount == 0 ? 1 : Double(correctCount) / Double(typedCount)
        let progress = promptCount == 0 ? 1 : min(Double(typedCount) / Double(promptCount), 1)
        let charactersPerMinute = minutes > 0 ? Double(correctCount) / minutes : 0
        let wordsPerMinute = charactersPerMinute / 5

        return TypingSpeedMetrics(
            typedCharacters: typedCount,
            correctCharacters: correctCount,
            errorCharacters: errorCount,
            elapsedSeconds: safeElapsedSeconds,
            progress: progress,
            accuracy: accuracy,
            wordsPerMinute: wordsPerMinute,
            charactersPerMinute: charactersPerMinute,
            isComplete: typedText == prompt
        )
    }
}
