import Foundation

enum AutoFixSkipReason: String {
    case belowThreshold = "below_threshold"
    case tooShort = "too_short"
    case containsDigits = "contains_digits"
    case blocklist = "blocklist"
    case allowlist = "allowlist"
    case recentlyRejected = "recently_rejected"
    case noTargetLayout = "no_target_layout"
    case missingMaps = "missing_maps"
    case identicalCandidate = "identical_candidate"
    case ambiguousTarget = "ambiguous_target"
    case originalIsRealWord = "original_is_real_word"
    case likelySpellingTypo = "likely_spelling_typo"
    case editingContext = "editing_context"
    case targetChanged = "target_changed"
    case targetUnverifiable = "target_unverifiable"
    case replacementNotCommitted = "replacement_not_committed"
    case unsafeEditor = "unsafe_editor"
    case multipleCursorRisk = "multiple_cursor_risk"
    case mixedLanguageIntentional = "mixed_language_intentional"
}
