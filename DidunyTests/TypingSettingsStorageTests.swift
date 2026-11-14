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
        #expect(settings.typingConvertEnabled)
        #expect(settings.typingConvertPair == .optionShift)
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
        settings.addTypingNeverFixWord("ghbdsn")
        settings.typingCustomReplaceRules = [CustomAutoReplaceRule(source: "nfrj;", target: "також")]
        settings.typingConvertEnabled = false
        settings.typingConvertPair = .commandShift

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

    // MARK: - Never-fix words and rules

    @Test("the allowlist is the never-fix words, then the Vocabulary terms, without duplicates")
    func allowlistUnion() {
        let settings = box.settings
        settings.speechVocabularyTerms = ["Kubernetes", "Diduny", "GHBDSN"]
        settings.addTypingNeverFixWord("ghbdsn")
        settings.addTypingNeverFixWord(" Ghbdsn ")
        settings.addTypingNeverFixWord("diduny")
        settings.addTypingNeverFixWord("  ")

        #expect(settings.typingNeverFixWords == ["ghbdsn", "diduny"])
        #expect(settings.typingSettings.autoFixAllowlist == ["ghbdsn", "diduny", "Kubernetes"])
        // "Never replace" words stay out of the Vocabulary list.
        #expect(settings.speechVocabularyTerms == ["Kubernetes", "Diduny", "GHBDSN"])
    }

    @Test("what the engine writes is in the very next read, also after the first read cached the settings")
    func writeThenRead() {
        let settings = box.settings
        _ = settings.typingSettings

        settings.addTypingNeverFixWord("ghbdsn")
        #expect(settings.typingSettings.autoFixAllowlist == ["ghbdsn"])

        let rule = CustomAutoReplaceRule(source: "nfrj;", target: "також", createdFromRecommendation: true)
        settings.typingCustomReplaceRules = [rule]
        #expect(settings.typingSettings.customAutoReplaceRules == [rule])

        settings.removeTypingNeverFixWord("GHBDSN")
        #expect(settings.typingSettings.autoFixAllowlist.isEmpty)
    }

    @Test("a Vocabulary change reaches the cached settings")
    func vocabularyChangeRefreshesTheCache() {
        let settings = box.settings
        #expect(settings.typingSettings.autoFixAllowlist.isEmpty)

        settings.speechVocabularyTerms = ["Kubernetes"]
        #expect(settings.typingSettings.autoFixAllowlist == ["Kubernetes"])

        settings.speechVocabularyTerms = []
        #expect(settings.typingSettings.autoFixAllowlist.isEmpty)
    }

    @Test("the never-fix words and the rules survive a new SettingsStorage on the same defaults")
    func survivesRelaunch() {
        let rule = CustomAutoReplaceRule(source: "nfrj;", target: "також", createdFromRecommendation: true, matchesFullToken: true)
        box.settings.typingCustomReplaceRules = [rule]
        box.settings.addTypingNeverFixWord("ghbdsn")

        let reopened = SettingsStorage(defaults: box.defaults)
        #expect(reopened.typingCustomReplaceRules == [rule])
        #expect(reopened.typingNeverFixWords == ["ghbdsn"])
        #expect(reopened.typingSettings.customAutoReplaceRules == [rule])
        #expect(reopened.typingSettings.autoFixAllowlist == ["ghbdsn"])
    }

    @Test("the engine's own writes post no change notification")
    func engineWritesAreQuiet() {
        var posts = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .typingSettingsChanged, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        box.settings.addTypingNeverFixWord("ghbdsn")
        box.settings.typingCustomReplaceRules = [CustomAutoReplaceRule(source: "a", target: "b")]
        #expect(posts == 0)
    }
}
