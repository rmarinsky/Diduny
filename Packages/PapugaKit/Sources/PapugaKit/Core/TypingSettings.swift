import Foundation

/// The Papuga settings the typing engine reads, as one value. Each property is named after its
/// Papuga key and defaults to Papuga's default (`papuga/Models/AppSettings.swift`).
/// The host owns the storage; the engine reads a fresh value through the provider it was given.
public struct TypingSettings: Equatable {
    public var autoFixAlgorithm: String = LanguageScorerAlgorithm.appleNL.rawValue
    /// Must stay in sync with `AutoFixSensitivityPreset.balanced`.
    public var autoFixThreshold: Double = 0.35
    public var autoFixCandidateSeparation: Double = 0.15
    public var autoFixMinWordLength: Int = 2
    public var autoFixBlocklist: [String] = []
    public var autoFixAllowlist: [String] = []
    public var autoFixToastEnabled: Bool = true
    public var autoFixConservativeEditingGuard: Bool = true
    public var autoFixSpellingTypoGuardEnabled: Bool = true
    public var autoFixSpellingTypoGuardMinWordLength: Int = 4
    public var autoFixSpellingTypoGuardMaxEditDistance: Int = 1
    public var autoFixProposalEnabled: Bool = true
    /// Must stay in sync with `AutoFixSensitivityPreset.balanced`.
    public var autoFixProposalWindow: Double = 0.22
    public var autoFixAppPolicyOverrides: [String: String] = [:]
    public var autoFixLayoutSwitchPolicy: String = AutoFixLayoutSwitchPolicy.alwaysSwitchToReplacementLayout.rawValue
    public var customAutoReplaceRules: [CustomAutoReplaceRule] = []
    /// Net WPM from the typing-speed test. 0 = not measured.
    public var measuredTypingWPM: Double = 0
    /// Smoothed inter-keystroke gap from `TypingCadenceTracker`. 0 = never measured.
    public var typingCadenceAverageGap: Double = 0
    /// Read by `LayoutManager`.
    public var layoutOrder: [String] = []
    /// Read by `LayoutManager`.
    public var disabledLayouts: [String] = []
    /// Read by `ReplacementHistoryStore` and `AutoFixDecisionHistoryStore`.
    public var replacementHistoryEnabled: Bool = true
    /// Read by `ReplacementHistoryStore` and `AutoFixDecisionHistoryStore`.
    public var replacementHistoryRetention: String = ReplacementHistoryRetention.oneMonth.rawValue

    public init() {}

    /// The values Papuga's Settings picker writes for a preset; every other value is kept.
    public func applying(_ preset: AutoFixSensitivityPreset) -> TypingSettings {
        var copy = self
        copy.autoFixMinWordLength = preset.minWordLength
        copy.autoFixThreshold = preset.threshold
        copy.autoFixProposalWindow = preset.proposalWindow
        copy.autoFixSpellingTypoGuardMinWordLength = preset.typoGuardMinWordLength
        copy.autoFixSpellingTypoGuardMaxEditDistance = preset.typoGuardMaxEditDistance
        return copy
    }

    static let careful = TypingSettings().applying(.careful)
    static let balanced = TypingSettings().applying(.balanced)
    static let moreHints = TypingSettings().applying(.moreHints)
}

/// Copied from Papuga `Views/Settings/AutoFixTab.swift` as plain data: the cases, the values and
/// `nearest`. The titles and descriptions stay with the host's settings screen.
///
/// `proposalWindow` gates how much of the sub-threshold band becomes a visible
/// proposal (wider = hints more). So `moreHints` deliberately has both the
/// highest threshold and the widest window: it trades silent replacement for
/// visible suggestions. Do not "fix" that into a monotonic threshold ramp.
///
/// `balanced` is the shipped default; keep it in sync with
/// `TypingSettings.autoFixThreshold` / `.autoFixProposalWindow`.
public enum AutoFixSensitivityPreset: String, CaseIterable, Identifiable {
    case careful
    case balanced
    case moreHints

    public var id: String { rawValue }

    var minWordLength: Int {
        switch self {
        case .careful: return 4
        case .balanced: return 2
        case .moreHints: return 2
        }
    }

    var threshold: Double {
        switch self {
        case .careful: return 0.45
        case .balanced: return 0.35
        case .moreHints: return 0.50
        }
    }

    var proposalWindow: Double {
        switch self {
        case .careful: return 0.14
        case .balanced: return 0.22
        case .moreHints: return 0.35
        }
    }

    var typoGuardMinWordLength: Int {
        switch self {
        case .careful: return 3
        case .balanced, .moreHints: return 4
        }
    }

    var typoGuardMaxEditDistance: Int {
        1
    }

    static func nearest(
        minWordLength: Int,
        threshold: Double,
        proposalWindow: Double
    ) -> AutoFixSensitivityPreset {
        allCases.min { lhs, rhs in
            lhs.distance(toMinWordLength: minWordLength, threshold: threshold, proposalWindow: proposalWindow)
                < rhs.distance(toMinWordLength: minWordLength, threshold: threshold, proposalWindow: proposalWindow)
        } ?? .balanced
    }

    private func distance(
        toMinWordLength minWordLength: Int,
        threshold: Double,
        proposalWindow: Double
    ) -> Double {
        abs(Double(self.minWordLength - minWordLength)) * 0.2
            + abs(self.threshold - threshold)
            + abs(self.proposalWindow - proposalWindow)
    }
}
