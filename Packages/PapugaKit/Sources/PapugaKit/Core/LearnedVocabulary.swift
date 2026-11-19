import Foundation

/// Words Papuga should treat as already handled / known-good, so they never
/// resurface as suggestions even if old open observations linger in the store:
/// the user's allowlist ("не чіпати"), and both sides of their custom rules
/// (a rule source is already handled; a rule target is a correct word).
enum LearnedVocabulary {
    static func knownGoodWords(
        allowlist: [String],
        rules: [CustomAutoReplaceRule]
    ) -> Set<String> {
        Set((allowlist + rules.map(\.target)).map { BufferedToken.normalizedCore(from: $0).lowercased() })
            .subtracting([""])
    }

    static func handledSources(
        allowlist: [String],
        rules: [CustomAutoReplaceRule]
    ) -> Set<String> {
        var set = knownGoodWords(allowlist: allowlist, rules: rules)
        for rule in rules {
            set.insert(BufferedToken.normalizedCore(from: rule.source).lowercased())
        }
        set.remove("")
        return set
    }
}
