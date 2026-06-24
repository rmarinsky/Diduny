import Testing
@testable import Diduny

struct TypingSpeedMeasurementTests {
    @Test("Perfect typing uses standard five-character WPM")
    func perfectTypingUsesFiveCharacterWords() {
        let result = TypingSpeedMeasurement.evaluate(
            typedText: "abcdefghij",
            targetText: "abcdefghij",
            elapsedSeconds: 30
        )

        #expect(result.grossWordsPerMinute == 4)
        #expect(result.netWordsPerMinute == 4)
        #expect(result.accuracy == 1)
        #expect(result.currentAccuracy == 1)
        #expect(result.processAccuracy == 1)
        #expect(result.completion == 1)
    }

    @Test("Incorrect characters reduce net WPM")
    func incorrectCharactersReduceNetWordsPerMinute() {
        let result = TypingSpeedMeasurement.evaluate(
            typedText: "abcxxxxxij",
            targetText: "abcdefghij",
            elapsedSeconds: 30
        )

        #expect(result.grossWordsPerMinute == 4)
        #expect(result.netWordsPerMinute == 2)
        #expect(result.accuracy == 0.5)
        #expect(result.currentAccuracy == 0.5)
        #expect(result.processAccuracy == 0.5)
        #expect(result.activeMistakeCount == 5)
    }

    @Test("Corrected mistakes still reduce process accuracy")
    func correctedMistakesStillReduceProcessAccuracy() {
        let result = TypingSpeedMeasurement.evaluate(
            typedText: "abcdefghij",
            targetText: "abcdefghij",
            elapsedSeconds: 30,
            totalInsertionCount: 12,
            incorrectInsertionCount: 2,
            correctionCount: 2,
            correctionTimeSeconds: 5
        )

        #expect(result.grossWordsPerMinute == 4)
        #expect(abs(result.processAccuracy - 0.8333) < 0.001)
        #expect(abs(result.accuracy - 0.8333) < 0.001)
        #expect(abs(result.netWordsPerMinute - 3.3333) < 0.001)
        #expect(result.currentAccuracy == 1)
        #expect(result.correctionCount == 2)
        #expect(result.correctionTimeSeconds == 5)
    }

    @Test("Typing speed setting clamps unreasonable values")
    func typingSpeedSettingClampsRange() {
        let originalValue = SettingsStorage.shared.typingSpeedWordsPerMinute
        defer {
            SettingsStorage.shared.typingSpeedWordsPerMinute = originalValue
        }

        SettingsStorage.shared.typingSpeedWordsPerMinute = 3
        #expect(SettingsStorage.shared.typingSpeedWordsPerMinute == 10)

        SettingsStorage.shared.typingSpeedWordsPerMinute = 240
        #expect(SettingsStorage.shared.typingSpeedWordsPerMinute == 160)

        SettingsStorage.shared.typingSpeedWordsPerMinute = 42.4
        #expect(SettingsStorage.shared.typingSpeedWordsPerMinute == 42)
    }
}
