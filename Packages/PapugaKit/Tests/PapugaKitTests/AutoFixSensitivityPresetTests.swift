import XCTest
@testable import PapugaKit

/// The Settings picker has no stored "which preset is selected" value — it
/// labels the current state by finding the nearest preset. That only tells the
/// truth if the shipped defaults actually *are* a preset.
final class AutoFixSensitivityPresetTests: XCTestCase {

    func test_shippedDefaults_areExactlyTheBalancedPreset() {
        let balanced = AutoFixSensitivityPreset.balanced
        XCTAssertEqual(TypingSettings().autoFixThreshold, balanced.threshold, accuracy: 0.0001)
        XCTAssertEqual(TypingSettings().autoFixProposalWindow, balanced.proposalWindow, accuracy: 0.0001)
        XCTAssertEqual(TypingSettings().autoFixMinWordLength, balanced.minWordLength)
        XCTAssertEqual(
            TypingSettings().autoFixSpellingTypoGuardMinWordLength,
            balanced.typoGuardMinWordLength
        )
        XCTAssertEqual(
            TypingSettings().autoFixSpellingTypoGuardMaxEditDistance,
            balanced.typoGuardMaxEditDistance
        )
    }

    /// A fresh install must resolve to the preset it claims in the UI.
    func test_nearest_resolvesShippedDefaultsToBalanced() {
        let preset = AutoFixSensitivityPreset.nearest(
            minWordLength: TypingSettings().autoFixMinWordLength,
            threshold: TypingSettings().autoFixThreshold,
            proposalWindow: TypingSettings().autoFixProposalWindow
        )
        XCTAssertEqual(preset, .balanced)
    }

    /// Round-trip: applying a preset must make `nearest` report that same
    /// preset back, otherwise the picker jumps to a different row on reopen.
    func test_everyPreset_roundTripsThroughNearest() {
        for preset in AutoFixSensitivityPreset.allCases {
            let resolved = AutoFixSensitivityPreset.nearest(
                minWordLength: preset.minWordLength,
                threshold: preset.threshold,
                proposalWindow: preset.proposalWindow
            )
            XCTAssertEqual(resolved, preset, "\(preset.rawValue) does not round-trip")
        }
    }

    /// `moreHints` intentionally has the *highest* auto-replace threshold: it
    /// shows more suggestions instead of replacing silently. Guard the two-axis
    /// design so nobody flattens it into a single aggressiveness ramp.
    func test_moreHints_replacesLessSilentlyButProposesMore() {
        let careful = AutoFixSensitivityPreset.careful
        let balanced = AutoFixSensitivityPreset.balanced
        let moreHints = AutoFixSensitivityPreset.moreHints

        // Proposal breadth strictly increases across the three presets.
        XCTAssertLessThan(careful.proposalWindow, balanced.proposalWindow)
        XCTAssertLessThan(balanced.proposalWindow, moreHints.proposalWindow)

        // Silent replacement is loosest in the middle, strictest at moreHints.
        XCTAssertLessThan(balanced.threshold, careful.threshold)
        XCTAssertLessThan(careful.threshold, moreHints.threshold)
    }
}
