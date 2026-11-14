import Foundation

enum AutoFixTokenKind: Equatable {
    case ordinary
    case acronym
    case productTerm
    case identifier
    case codeLike
    case versionLike
}

enum MixedLanguageDecision: Equatable {
    case autoReplace
    case propose
    case skipAsIntentional(AutoFixTokenKind)
}

enum AutoFixTokenClassifier {
    static func classify(_ token: String) -> AutoFixTokenKind {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ordinary }

        if isKnownProductTerm(trimmed) {
            return .productTerm
        }

        if isAcronym(trimmed) {
            return .acronym
        }

        if isVersionLike(trimmed) {
            return .versionLike
        }

        if isIdentifierLike(trimmed) {
            return .identifier
        }

        if isCodeLike(trimmed) {
            return .codeLike
        }

        return .ordinary
    }

    static func isIntentionalMixedLanguageToken(_ token: String) -> Bool {
        classify(token) != .ordinary
    }

    private static func isAcronym(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        guard (2...12).contains(scalars.count) else { return false }
        guard scalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) || $0 == "&" }) else {
            return false
        }
        return scalars.contains { CharacterSet.uppercaseLetters.contains($0) }
    }

    private static func isKnownProductTerm(_ token: String) -> Bool {
        guard let match = ProtectedLexiconStore.shared.match(token) else { return false }
        return match.protectsSource && (
            match.entry.category == .brand
                || match.entry.category == .product
                || match.entry.category == .organization
                || match.entry.category == .domain
        )
    }

    private static func isVersionLike(_ token: String) -> Bool {
        guard token.contains(where: \.isNumber) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-/+_"))
        return token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isIdentifierLike(_ token: String) -> Bool {
        if token.contains("_") || token.contains("-") {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            return token.unicodeScalars.allSatisfy { allowed.contains($0) }
        }

        guard token.count >= 3 else { return false }
        let chars = Array(token)
        let hasLower = chars.contains(where: { $0.isLowercase })
        let hasUpper = chars.contains(where: { $0.isUppercase })
        guard hasLower, hasUpper else { return false }

        // camelCase / PascalCase; all-caps acronyms are handled above.
        return token.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private static func isCodeLike(_ token: String) -> Bool {
        let lower = token.lowercased()
        if knownCodeTerms.contains(lower) {
            return true
        }

        if lower.hasPrefix("/") || lower.hasPrefix("~/") || lower.hasPrefix("./") || lower.hasPrefix("../") {
            return true
        }

        if lower.contains("/") && !lower.contains("://") {
            return true
        }

        if lower.contains(".") {
            let suffix = lower.split(separator: ".").last.map(String.init) ?? ""
            if codeFileExtensions.contains(suffix) {
                return true
            }
        }

        return false
    }

    private static let knownCodeTerms: Set<String> = [
        "git",
        "npm",
        "pnpm",
        "yarn",
        "node",
        "swift",
        "xcodebuild",
        "localhost",
        "ssh",
        "json",
        "yaml",
        "http",
        "https",
        "api",
        "rest",
        "graphql"
    ]

    private static let codeFileExtensions: Set<String> = [
        "swift",
        "js",
        "ts",
        "tsx",
        "jsx",
        "json",
        "yaml",
        "yml",
        "md",
        "html",
        "css",
        "py",
        "java",
        "kt",
        "go",
        "rs"
    ]
}

enum AutoFixMixedLanguagePolicy {
    static func decision(
        original: String,
        candidate: String,
        currentLanguage: String,
        targetLanguage: String,
        scoreOriginal: Double,
        scoreCandidate: Double,
        threshold: Double,
        verifiedLayoutWord: Bool = false
    ) -> MixedLanguageDecision {
        let kind = AutoFixTokenClassifier.classify(original)
        let isNaturalWordShape = !original.contains("_") && (
            original.contains("-") ||
            (original.first?.isUppercase == true && original.dropFirst().allSatisfy { !$0.isUppercase })
        )
        let verifiedNaturalWord = verifiedLayoutWord && kind == .identifier && isNaturalWordShape
        if kind != .ordinary, !verifiedNaturalWord, containsLatinLetter(original) {
            return .skipAsIntentional(kind)
        }

        let margin = scoreCandidate - scoreOriginal
        if margin > 0, margin < threshold {
            return .propose
        }

        return .autoReplace
    }

    private static func containsLatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
        }
    }
}
