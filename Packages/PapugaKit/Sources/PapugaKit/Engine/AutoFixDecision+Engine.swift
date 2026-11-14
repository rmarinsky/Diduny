import AppKit
import Carbon.HIToolbox
import Foundation

struct SpellingTypoGuardAssessment: Equatable {
    let shouldSuppressAutoReplace: Bool
    let suggestion: String?
    let editDistance: Int?
}

/// What to do with a layout candidate once the dictionary has had its say.
/// The previous boolean collapsed three genuinely different situations into
/// "suppress", which is why an unsupported target language and a word the
/// dictionary actively rejects were treated identically.
enum LayoutReplacementGate: Equatable {
    /// The target is dictionary-attested. Continue to scoring.
    case allow
    /// Plausible, but nothing can verify it — suggest, never silently mutate.
    case requireProposal
    /// A dictionary says the target is not a word. Fail closed.
    case suppress
}

extension AutoFixDecision {
    /// Preserves the fail-closed intent this gate was added with — a target the
    /// dictionary rejects is still never auto-replaced — while no longer
    /// treating "we have no dictionary for this language" as the same thing.
    ///
    /// `.unavailable` used to mean silence: layout auto-fix was entirely dead
    /// for any target language without a bundled index (ru, pl, de, …) and for
    /// every language during the async index load at launch. A word-like
    /// candidate in that state is now offered as a proposal, which is the
    /// honest answer — Papuga thinks this is the fix but cannot prove it.
    static func layoutReplacementGate(
        mappedSpellingStatus: MappedSpellingStatus,
        candidateIsWordLike: Bool
    ) -> LayoutReplacementGate {
        switch mappedSpellingStatus {
        case .correct:
            return .allow
        case .misspelled:
            return .suppress
        case .unavailable:
            return candidateIsWordLike ? .requireProposal : .suppress
        }
    }

    static func shouldSuppressLayoutReplacement(
        mappedSpellingStatus: MappedSpellingStatus,
        candidateIsWordLike: Bool = false
    ) -> Bool {
        layoutReplacementGate(
            mappedSpellingStatus: mappedSpellingStatus,
            candidateIsWordLike: candidateIsWordLike
        ) == .suppress
    }

    static func compoundLayoutSpellingSuggestion(
        mapped: String,
        targetLanguage: String,
        isMisspelled: (String, String) -> Bool,
        guesses: (String, String) -> [String]
    ) -> String? {
        guard isMisspelled(mapped, targetLanguage) else { return nil }
        return guesses(mapped, targetLanguage).prefix(3).compactMap { suggestion in
            let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains(where: \.isWhitespace),
                  trimmed.caseInsensitiveCompare(mapped) != .orderedSame,
                  WordPlausibility.isWordLike(trimmed) else { return nil }
            return trimmed
        }.first
    }

    /// How long after a replacement a delete still reads as taking it back.
    static func isImplicitUndoWindow(elapsed: TimeInterval) -> Bool {
        elapsed >= 0 && elapsed <= 6
    }

    static func shouldBypassLayoutIncidentGrace(scoreCandidate: Double, hasVerifiedLayoutWord: Bool = false) -> Bool {
        hasVerifiedLayoutWord || scoreCandidate >= 0.995
    }

    static func shouldSuggestPhraseLayoutMistake(
        original: String,
        candidate: String,
        targetLanguage: String,
        scoreCandidate: Double
    ) -> Bool {
        let originalWords = words(in: original)
        let candidateWords = words(in: candidate).map { $0.lowercased() }
        guard targetLanguage.lowercased() == "en",
              originalWords.count >= 3,
              candidateWords.count >= 3,
              scoreCandidate >= 0.70,
              isCrossScriptConversion(original: original, candidate: candidate),
              containsCyrillicLetter(original),
              containsLatinLetter(candidate)
        else {
            return false
        }

        let commonHits = candidateWords.filter { commonEnglishPhraseWords.contains($0) }.count
        let hasMeaningfulWord = candidateWords.contains { $0.count >= 5 }
        return commonHits >= 2 && hasMeaningfulWord
    }

    static func shouldSuggestSingleTokenLayoutMistake(
        original: String,
        candidate: String,
        targetLanguage: String,
        scoreCandidate: Double
    ) -> Bool {
        guard original.count >= 3,
              candidate.count >= 3,
              scoreCandidate >= 0.64,
              isCrossScriptConversion(original: original, candidate: candidate)
        else {
            return false
        }

        let normalizedLanguage = targetLanguage.lowercased()
        if normalizedLanguage == "uk" || normalizedLanguage == "ru" {
            return containsCyrillicLetter(candidate) && !containsLatinLetter(candidate)
        }

        return containsLatinLetter(candidate) && !containsCyrillicLetter(candidate)
    }

    static func shouldSuppressPhraseAutoReplace(
        original: String,
        candidate: String,
        sourceLanguage: String,
        targetLanguage: String,
        allowlist: [String],
        isKnownCorrect: ((String, String) -> Bool)? = nil
    ) -> Bool {
        let source = sourceLanguage.lowercased()
        let target = targetLanguage.lowercased()
        guard source == "en",
              target == "uk" || target == "ru",
              isCrossScriptConversion(original: original, candidate: candidate)
        else {
            return false
        }

        let originalWords = words(in: original)
        guard originalWords.count >= 3 else { return false }
        let spellcheck = isKnownCorrect ?? { word, language in
            AutoFixDecision.isCorrectlySpelled(word, language: language)
        }

        return originalWords.allSatisfy { word in
            isInAllowlist(word, allowlist: allowlist)
                || ProtectedLexiconStore.shared.isProtectedSource(word)
                || AutoFixTokenClassifier.isIntentionalMixedLanguageToken(word)
                || spellcheck(word, source)
        }
    }

    static func isWordBoundary(keyCode: UInt16, typedString: String) -> Bool {
        // Only whitespace is a universal word boundary. Punctuation like ';' or ','
        // is layout-dependent: ';' on US is `ж` on Ukrainian-PC, ',' on US is `б`
        // on Russian, etc. Treating them as boundaries prematurely flushes the
        // word buffer mid-word and prevents auto-fix from seeing the full token.
        let kVK_Space: UInt16 = 0x31
        let kVK_Return: UInt16 = 0x24
        let kVK_Tab: UInt16 = 0x30
        return keyCode == kVK_Space || keyCode == kVK_Return || keyCode == kVK_Tab
    }

    /// Languages `languageHintForLayoutID` can name — the set to test a word
    /// against when the caller has text but no layout to derive a language from.
    static let supportedSpellingLanguages = [
        "uk", "ru", "pl", "de", "fr", "es", "it", "tr", "ar", "he", "en"
    ]

    private static let languageCacheLock = NSLock()
    private static var languageCache: [String: String] = [:]

    static func invalidateLanguageHints() {
        languageCacheLock.withLock { languageCache.removeAll() }
    }

    static func languageHintForLayoutID(_ layoutID: String) -> String {
        if let cached = languageCacheLock.withLock({ languageCache[layoutID] }) { return cached }
        let query = [kTISPropertyInputSourceID!: layoutID] as CFDictionary
        let sources = TISCreateInputSourceList(query, true)?.takeRetainedValue() as? [TISInputSource]
        let code: String
        if let source = sources?.first,
           let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
            code = String((languages?.first ?? "").prefix { $0 != "-" && $0 != "_" }).lowercased()
        } else {
            code = ""
        }
        languageCacheLock.withLock { languageCache[layoutID] = code }
        return code
    }

    /// True when the word is in the system spell-check dictionary for the
    /// given language. Used to short-circuit auto-fix when the user typed a
    /// legitimate word: e.g. `faster` in EN scores ~0.5 as English while the
    /// Cyrillic gibberish candidate `афіеук` scores ~0.99 as Ukrainian (Apple
    /// NL is mostly script detection on short text), which otherwise crosses
    /// the threshold and produces a false positive.
    /// 1-entry memo. Per word boundary, `evaluateAndMaybeFix` first calls this for the
    /// `originalIsRealWord` guard and the spelling-typo guard then calls it again for the same
    /// (word, language); the memo serves the second call instead of issuing a duplicate synchronous
    /// NSSpellChecker IPC round-trip. All callers run on the main actor. Correctness-neutral: it
    /// only short-circuits an immediately-repeated identical query.
    private static var lastSpellCheck: (word: String, language: String, result: Bool)?

    static func isCorrectlySpelled(_ word: String, language: String) -> Bool {
        if let memo = lastSpellCheck, memo.word == word, memo.language == language {
            return memo.result
        }
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        let result = range.location == NSNotFound || range.length == 0
        lastSpellCheck = (word, language, result)
        return result
    }

    /// Prevents layout auto-fix from punishing normal spelling mistakes.
    ///
    /// Example: `fster` in an English layout is likely a typo for `faster`;
    /// AppleNL may still score the Ukrainian-layout candidate very highly
    /// because it mostly sees Cyrillic script. In that case we should record a
    /// spelling observation, not mutate the user's word into another layout.
    static func spellingTypoGuardAssessment(
        original: String,
        candidate: String,
        language: String,
        minWordLength: Int = 4,
        maxEditDistance: Int = 1,
        isKnownCorrect: ((String, String) -> Bool)? = nil,
        suggestions: ((String, String) -> [String])? = nil
    ) -> SpellingTypoGuardAssessment {
        let word = normalizedSpellcheckToken(original)
        let spellcheck = isKnownCorrect ?? { word, language in
            AutoFixDecision.isCorrectlySpelled(word, language: language)
        }
        guard word.count >= minWordLength,
              maxEditDistance >= 0,
              scriptMatches(language: language, word: word),
              isCrossScriptConversion(original: word, candidate: candidate),
              !spellcheck(word, language)
        else {
            return SpellingTypoGuardAssessment(
                shouldSuppressAutoReplace: false,
                suggestion: nil,
                editDistance: nil
            )
        }

        let guesses = (suggestions ?? spellingSuggestions)(word, language)

        let best = guesses
            .prefix(8)
            .map { suggestion in
                (suggestion, spellingEditDistance(word.lowercased(), suggestion.lowercased()))
            }
            .min { lhs, rhs in lhs.1 < rhs.1 }

        guard let best,
              best.1 <= maxEditDistance
        else {
            return SpellingTypoGuardAssessment(
                shouldSuppressAutoReplace: false,
                suggestion: best?.0,
                editDistance: best?.1
            )
        }

        return SpellingTypoGuardAssessment(
            shouldSuppressAutoReplace: true,
            suggestion: best.0,
            editDistance: best.1
        )
    }

    private static func spellingSuggestions(for word: String, language: String) -> [String] {
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.guesses(
            forWordRange: range,
            in: word,
            language: language,
            inSpellDocumentWithTag: 0
        ) ?? []
    }

    private static func normalizedSpellcheckToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}<>\"'`“”‘’"))
    }

    private static func words(in text: String) -> [String] {
        text.split { !$0.isLetter }.map(String.init)
    }

    private static func scriptMatches(language: String, word: String) -> Bool {
        let hasLatin = containsLatinLetter(word)
        let hasCyrillic = containsCyrillicLetter(word)
        let normalizedLanguage = language.lowercased()

        if normalizedLanguage == "uk" || normalizedLanguage == "ru" {
            return hasCyrillic && !hasLatin
        }

        return hasLatin && !hasCyrillic
    }

    private static let commonEnglishPhraseWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "can", "do",
        "for", "from", "have", "i", "if", "in", "is", "it", "my", "not",
        "of", "on", "or", "our", "that", "the", "this", "to", "we", "what",
        "when", "with", "you", "your"
    ]
}
