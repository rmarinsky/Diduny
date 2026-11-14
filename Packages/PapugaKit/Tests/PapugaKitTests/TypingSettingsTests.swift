import XCTest
@testable import PapugaKit

/// The literals are Papuga's defaults from `papuga/Models/AppSettings.swift` at 58948a5.
final class TypingSettingsTests: XCTestCase {
    func test_defaultsEqualPapugaDefaults() {
        let settings = TypingSettings()
        XCTAssertEqual(settings.autoFixAlgorithm, "appleNL")
        XCTAssertEqual(settings.autoFixAlgorithm, LanguageScorerAlgorithm.appleNL.rawValue)
        XCTAssertEqual(settings.autoFixThreshold, 0.35)
        XCTAssertEqual(settings.autoFixCandidateSeparation, 0.15)
        XCTAssertEqual(settings.autoFixMinWordLength, 2)
        XCTAssertEqual(settings.autoFixBlocklist, [])
        XCTAssertEqual(settings.autoFixAllowlist, [])
        XCTAssertEqual(settings.autoFixToastEnabled, true)
        XCTAssertEqual(settings.autoFixConservativeEditingGuard, true)
        XCTAssertEqual(settings.autoFixSpellingTypoGuardEnabled, true)
        XCTAssertEqual(settings.autoFixSpellingTypoGuardMinWordLength, 4)
        XCTAssertEqual(settings.autoFixSpellingTypoGuardMaxEditDistance, 1)
        XCTAssertEqual(settings.autoFixProposalEnabled, true)
        XCTAssertEqual(settings.autoFixProposalWindow, 0.22)
        XCTAssertEqual(settings.autoFixAppPolicyOverrides, [:])
        XCTAssertEqual(settings.autoFixLayoutSwitchPolicy, "alwaysSwitchToReplacementLayout")
        XCTAssertEqual(settings.autoFixLayoutSwitchPolicy, AutoFixLayoutSwitchPolicy.alwaysSwitchToReplacementLayout.rawValue)
        XCTAssertEqual(settings.customAutoReplaceRules, [])
        XCTAssertEqual(settings.measuredTypingWPM, 0)
        XCTAssertEqual(settings.typingCadenceAverageGap, 0)
        XCTAssertEqual(settings.layoutOrder, [])
        XCTAssertEqual(settings.disabledLayouts, [])
        XCTAssertEqual(settings.replacementHistoryEnabled, true)
        XCTAssertEqual(settings.replacementHistoryRetention, "oneMonth")
        XCTAssertEqual(settings.replacementHistoryRetention, ReplacementHistoryRetention.oneMonth.rawValue)
    }

    /// The literals are the values of `AutoFixSensitivityPreset` in Papuga `Views/Settings/AutoFixTab.swift`.
    func test_eachPresetWritesPapugasValues() {
        let expected: [(TypingSettings, Int, Double, Double, Int, Int)] = [
            (.careful, 4, 0.45, 0.14, 3, 1),
            (.balanced, 2, 0.35, 0.22, 4, 1),
            (.moreHints, 2, 0.50, 0.35, 4, 1),
        ]
        for (settings, minWordLength, threshold, proposalWindow, typoMin, typoDistance) in expected {
            XCTAssertEqual(settings.autoFixMinWordLength, minWordLength)
            XCTAssertEqual(settings.autoFixThreshold, threshold)
            XCTAssertEqual(settings.autoFixProposalWindow, proposalWindow)
            XCTAssertEqual(settings.autoFixSpellingTypoGuardMinWordLength, typoMin)
            XCTAssertEqual(settings.autoFixSpellingTypoGuardMaxEditDistance, typoDistance)
        }
        XCTAssertEqual(TypingSettings.balanced, TypingSettings())
    }

    func test_applyingAPresetKeepsEveryOtherValue() {
        var settings = TypingSettings()
        settings.autoFixBlocklist = ["com.example.app"]
        settings.autoFixToastEnabled = false
        settings.autoFixCandidateSeparation = 0.3
        var expected = settings
        expected.autoFixMinWordLength = 4
        expected.autoFixThreshold = 0.45
        expected.autoFixProposalWindow = 0.14
        expected.autoFixSpellingTypoGuardMinWordLength = 3
        expected.autoFixSpellingTypoGuardMaxEditDistance = 1
        XCTAssertEqual(settings.applying(.careful), expected)
    }
}
