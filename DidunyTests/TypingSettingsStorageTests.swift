@testable import Diduny
import Foundation
import PapugaKit
import Testing

/// The `typing.` keys and the `TypingSettings` built from them.
@MainActor
final class TypingSettingsStorageTests {
    private let box = IsolatedSettings("TypingSettingsStorageTests")

    @Test("clean defaults: Typing is off and the engine gets its own defaults")
    func defaults() {
        let settings = box.settings
        #expect(!settings.typingEnabled)
        #expect(settings.typingSensitivity == .balanced)
        #expect(settings.typingSwitchLayoutAfterFix)
        #expect(settings.typingUndoHintEnabled)
        #expect(settings.typingDisabledApps.isEmpty)
        #expect(settings.typingCadenceAverageGap == 0)
        #expect(settings.typingSettings == TypingSettings())
    }

    @Test("every key starts with typing. and nothing else is written")
    func keysAreNamespaced() {
        let settings = box.settings
        let before = Set(box.defaults.dictionaryRepresentation().keys)

        settings.typingEnabled = true
        settings.typingSensitivity = .careful
        settings.typingSwitchLayoutAfterFix = false
        settings.typingUndoHintEnabled = false
        settings.typingDisabledApps = ["com.apple.Terminal"]
        settings.typingCadenceAverageGap = 0.2

        let written = Set(box.defaults.dictionaryRepresentation().keys).subtracting(before)
        #expect(written == Set(SettingsStorage.TypingKey.allCases.map(\.rawValue)))
        #expect(written.allSatisfy { $0.hasPrefix("typing.") })
    }

    @Test("a written value reaches the built settings, also after the first read cached them")
    func builtSettingsFollowTheKeys() {
        let settings = box.settings
        _ = settings.typingSettings

        settings.typingSensitivity = .careful
        settings.typingSwitchLayoutAfterFix = false
        settings.typingUndoHintEnabled = false
        settings.typingDisabledApps = ["com.apple.Terminal"]
        settings.typingCadenceAverageGap = 0.2

        var expected = TypingSettings().applying(.careful)
        expected.autoFixLayoutSwitchPolicy = AutoFixLayoutSwitchPolicy.keepCurrentLayout.rawValue
        expected.autoFixToastEnabled = false
        expected.autoFixBlocklist = ["com.apple.Terminal"]
        expected.typingCadenceAverageGap = 0.2
        #expect(settings.typingSettings == expected)
        #expect(expected != TypingSettings())
    }

    @Test("a setting posts the change notification; the cadence the engine writes does not")
    func changeNotification() {
        var posts = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .typingSettingsChanged, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        box.settings.typingCadenceAverageGap = 0.3
        #expect(posts == 0)

        box.settings.typingEnabled = true
        #expect(posts == 1)
    }
}
