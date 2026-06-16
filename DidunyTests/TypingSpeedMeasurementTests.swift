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
