import Foundation

struct CustomAutoReplaceRule: Codable, Identifiable, Hashable {
    let id: UUID
    var source: String
    var target: String
    var createdAt: Date
    var createdFromRecommendation: Bool
    /// `nil` decodes old rules as core-matching; `true` is reserved for exact
    /// layout mappings such as `nfrj; -> також`, where `;` is a letter key.
    var matchesFullToken: Bool?

    init(
        id: UUID = UUID(),
        source: String,
        target: String,
        createdAt: Date = Date(),
        createdFromRecommendation: Bool = false,
        matchesFullToken: Bool = false
    ) {
        self.id = id
        self.source = source
        self.target = target
        self.createdAt = createdAt
        self.createdFromRecommendation = createdFromRecommendation
        self.matchesFullToken = matchesFullToken
    }

    func matches(_ word: String) -> Bool {
        let candidate = matchesFullToken == true
            ? word
            : BufferedToken(rawText: word, keyCodes: []).core
        return source.caseInsensitiveCompare(candidate) == .orderedSame
    }

    func matches(_ token: BufferedToken) -> Bool {
        source.caseInsensitiveCompare(matchesFullToken == true ? token.rawText : token.core) == .orderedSame
    }

    func hasSameMatchScope(as other: CustomAutoReplaceRule) -> Bool {
        hasSameMatchScope(source: other.source, matchesFullToken: other.matchesFullToken == true)
    }

    func hasSameMatchScope(source otherSource: String, matchesFullToken otherMatchesFullToken: Bool) -> Bool {
        guard (matchesFullToken == true) == otherMatchesFullToken else { return false }
        let lhs = matchesFullToken == true ? source : BufferedToken.normalizedCore(from: source)
        let rhs = otherMatchesFullToken ? otherSource : BufferedToken.normalizedCore(from: otherSource)
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
