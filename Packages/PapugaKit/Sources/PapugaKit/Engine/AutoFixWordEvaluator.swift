import Carbon.HIToolbox
import Foundation

/// The synchronous production decision for one completed token. OS focus, editor mutation,
/// and phrase timing belong to the controller; mapping, dictionaries, and safety gates live here.
struct AutoFixWordEvaluation {
    enum Disposition: Equatable {
        case keep(AutoFixSkipReason)
        case sourceWord
        case shortWord
        case uncertain
        case suggestLayout
        case suggestSpelling(SpellingTypoGuardAssessment)
        case suggestCompound(String)
        /// A single finger slip in the current language — see `NarrowTypoCorrector`.
        case fixSpelling(String)
        case replace
    }

    let disposition: Disposition
    let scoreOriginal: Double
    let candidates: [AutoFixTargetCandidate]
    let selection: AutoFixCandidateGenerator.Selection?
    let effectiveScore: Double
    let threshold: Double

    var replacement: AutoFixTargetCandidate? {
        disposition == .replace ? selection?.best : nil
    }
}

struct AutoFixWordEvaluator {
    struct Configuration {
        var minimumLength = 2
        var threshold = 0.35
        var candidateSeparation = 0.15
        var spellingTypoGuardEnabled = true
        var spellingTypoGuardMinimumLength = 4
        var spellingTypoGuardMaximumDistance = 1
    }

    let mapper: CharacterMapper
    let spellChecker: SpellCheckingClient
    let scorer: LanguageScorer

    func evaluate(
        _ word: String,
        source: InputSourceInfo?,
        targets: [InputSourceInfo],
        configuration config: Configuration,
        previousWord: String? = nil
    ) -> AutoFixWordEvaluation {
        var originalScore = 0.0
        var candidates: [AutoFixTargetCandidate] = []
        var selection: AutoFixCandidateGenerator.Selection?
        var effectiveScore = 0.0
        var threshold = config.threshold
        func result(_ disposition: AutoFixWordEvaluation.Disposition) -> AutoFixWordEvaluation {
            AutoFixWordEvaluation(disposition: disposition, scoreOriginal: originalScore,
                candidates: candidates, selection: selection, effectiveScore: effectiveScore, threshold: threshold)
        }

        if ProtectedLexiconStore.shared.match(word)?.protectsSource == true {
            return result(.keep(.mixedLanguageIntentional))
        }
        let skip = AutoFixDecision.shouldSkipWord(word, minLength: config.minimumLength)
        if skip == .containsDigits || skip == .containsForbiddenChars { return result(.keep(.containsDigits)) }
        guard !targets.isEmpty else { return result(.keep(.noTargetLayout)) }
        guard let source else { return result(.keep(.missingMaps)) }
        let currentLanguage = AutoFixDecision.languageHintForLayoutID(source.id)
        guard !currentLanguage.isEmpty else { return result(.keep(.missingMaps)) }
        mapper.buildMap(for: source.source, sourceID: source.id)
        originalScore = scorer.score(word, expecting: currentLanguage)
        for target in targets {
            mapper.buildMap(for: target.source, sourceID: target.id)
            let language = AutoFixDecision.languageHintForLayoutID(target.id)
            guard !language.isEmpty else { continue }
            var inner = word
            var leadingWrapper = "", trailingWrapper = ""
            let wrappers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "«": "»", "“": "”"]
            while inner.count > 2, let first = inner.first, let last = inner.last, wrappers[first] == last {
                leadingWrapper.append(first)
                trailingWrapper.insert(last, at: trailingWrapper.startIndex)
                inner = String(inner.dropFirst().dropLast())
            }
            let mapped = mapper.convert(text: inner, fromSourceID: source.id, toSourceID: target.id)
            guard mapped != inner else { continue }
            let token = BufferedToken(rawText: inner, keyCodes: [])
            let coreMapped = mapper.convert(text: token.core, fromSourceID: source.id, toSourceID: target.id)
            let fullValid = Self.isLexicalToken(mapped) && spellChecker.mappedSpellingStatus(mapped, language: language) == .correct
            let coreValid = Self.isLexicalToken(coreMapped) && spellChecker.mappedSpellingStatus(coreMapped, language: language) == .correct
            let interpretation = LayoutInterpretationPolicy.select(token: token,
                fullMapped: mapped, coreMapped: coreMapped, fullIsValid: fullValid, coreIsValid: coreValid, boundary: " ")
            var innerPlan = interpretation.suggestions.first
            var ambiguous = interpretation.isSuggestionOnly
            // Leading physical-letter keys (e.g. ];f -> їжа) are not English word punctuation.
            // For a trailing key, require a substantial frequency advantage to resolve two real words.
            if ambiguous && fullValid && (!token.leadingEdge.isEmpty ||
                spellChecker.logFrequency(of: mapped, language: language) - spellChecker.logFrequency(of: coreMapped, language: language) >= log10(4)) {
                ambiguous = false
            }
            if let chosen = innerPlan {
                innerPlan = ReplacementPlan(rawSource: word, correctedCore: chosen.correctedCore,
                    preservedLeadingPunctuation: leadingWrapper + chosen.preservedLeadingPunctuation,
                    preservedTrailingPunctuation: chosen.preservedTrailingPunctuation + trailingWrapper,
                    renderedReplacement: leadingWrapper + chosen.renderedReplacement + trailingWrapper,
                    boundary: " ", interpretationReason: chosen.interpretationReason)
            }
            candidates.append(AutoFixTargetCandidate(targetID: target.id, targetLang: language,
                candidate: innerPlan?.renderedReplacement ?? (leadingWrapper + mapped + trailingWrapper),
                scoreCandidate: min(1, scorer.score(innerPlan?.correctedCore ?? mapped, expecting: language)
                    + PersonalLayoutModel.shared.boost(original: inner, candidate: innerPlan?.correctedCore ?? mapped,
                        sourceID: source.id, targetID: target.id, previousWord: previousWord)),
                replacementPlan: innerPlan, isInterpretationAmbiguous: ambiguous))
        }
        // An unsupported target's language score cannot outrank an exact dictionary match.
        let attested = candidates.filter { $0.replacementPlan != nil }
        selection = AutoFixCandidateGenerator.select(candidates: attested.isEmpty ? candidates : attested,
            scoreOriginal: originalScore, threshold: threshold, separation: config.candidateSeparation)
        if let ranked = selection, !attested.isEmpty {
            let meanings = Set(attested.map { $0.targetLang + ":" + $0.candidate })
            let preferred = attested.filter {
                PersonalLayoutModel.shared.hasContextPreference(original: word,
                    candidate: $0.replacementPlan?.correctedCore ?? $0.candidate,
                    sourceID: source.id, targetID: $0.targetID, previousWord: previousWord)
            }
            if meanings.count > 1, preferred.count == 1, let learned = preferred.first {
                selection = .init(best: learned, runnerUp: attested.first { $0.targetID != learned.targetID }, isAmbiguous: false)
            } else {
                selection = .init(best: ranked.best, runnerUp: ranked.runnerUp, isAmbiguous: meanings.count > 1)
            }
        }
        guard let best = selection?.best else { return result(.keep(.identicalCandidate)) }
        effectiveScore = best.scoreCandidate
        if skip == .tooShort { return result(.shortWord) }
        let hasCore = !BufferedToken(rawText: word, keyCodes: []).core.isEmpty
        // Source spelling must not depend on whether a target interpretation
        // succeeded. A comma or closing bracket cannot invalidate a real word.
        let sourceToken = BufferedToken(rawText: word, keyCodes: [])
        // A one-letter remainder is not evidence against a verified leading-key
        // conversion such as ];f → їжа (the stripped remainder is English "f").
        let consumesLeadingLetterKeys = best.replacementPlan?.interpretationReason == .layoutFullToken
            && !sourceToken.leadingEdge.isEmpty && sourceToken.core.count == 1
        let sourceWord = consumesLeadingLetterKeys ? word : sourceToken.core
        let lexicalCandidate = best.replacementPlan?.correctedCore ?? best.candidate
        // NSSpellChecker accepts consonant-only abbreviations such as yt, wt and vtys.
        // Only prefer a frequent cross-script word when the short lowercase source has
        // no English vowel and neither bundled nor learned vocabulary attests it.
        let isUnattestedAbbreviation = currentLanguage == "en"
            && (2...4).contains(sourceWord.count)
            && sourceWord.allSatisfy { ("a"..."z").contains(String($0)) }
            && !sourceWord.contains(where: { "aeiou".contains($0) })
            && !spellChecker.isExplicitlyKnown(sourceWord, language: currentLanguage)
            && spellChecker.logFrequency(of: lexicalCandidate, language: best.targetLang) >= 3
            && AutoFixDecision.isCrossScriptConversion(original: sourceWord, candidate: lexicalCandidate)
        if hasCore && Self.isLexicalToken(sourceWord) && !isUnattestedAbbreviation
            && !spellChecker.isMisspelled(sourceWord, language: currentLanguage) {
            return result(.sourceWord)
        }

        let spellingStatus = spellChecker.mappedSpellingStatus(lexicalCandidate, language: best.targetLang)
        if best.isInterpretationAmbiguous { return result(.suggestLayout) }
        switch AutoFixDecision.layoutReplacementGate(mappedSpellingStatus: spellingStatus,
            candidateIsWordLike: WordPlausibility.isWordLike(lexicalCandidate)) {
        case .requireProposal: return result(.suggestLayout)
        case .suppress:
            // A spell-check guess cannot establish that the layout was wrong.
            // Require independent evidence before asking the target dictionary.
            if spellingStatus == .misspelled, Self.isLexicalToken(best.candidate),
               AutoFixDecision.shouldReplace(scoreOriginal: originalScore,
                   scoreCandidate: best.scoreCandidate, threshold: threshold),
               let suggestion = AutoFixDecision.compoundLayoutSpellingSuggestion(mapped: best.candidate,
                   targetLanguage: best.targetLang, isMisspelled: { _, _ in true },
                   guesses: { spellChecker.guesses(for: $0, language: $1) }) {
                return result(.suggestCompound(suggestion))
            }
            // Not a layout mistake at all: the mapped text is no word either.
            if config.spellingTypoGuardEnabled,
               let fixed = NarrowTypoCorrector.correction(for: word, language: currentLanguage,
                   spellChecker: spellChecker,
                   keyCode: { mapper.mapping(for: $0, sourceID: source.id)?.keyCode }) {
                return result(.fixSpelling(fixed))
            }
            // Slang and jargon are in no dictionary (`засетаплено`, `онсайт`),
            // so a missing dictionary entry cannot veto the conversion by
            // itself — see `isUndictionariedLayoutSlip`.
            guard Self.isLexicalToken(sourceWord),
                  Self.isUndictionariedLayoutSlip(source: sourceWord, candidate: lexicalCandidate,
                      scoreOriginal: originalScore, scoreCandidate: best.scoreCandidate)
            else { return result(.keep(.belowThreshold)) }
            return result(selection?.isAmbiguous == true ? .suggestLayout : .replace)
        case .allow: break
        }
        // A language score is not the probability that a word is spelled correctly.
        // Exact cross-script dictionary evidence remains useful even when AppleNL cannot
        // identify the language of a short, isolated word.
        let verifiedLayoutWord = spellingStatus == .correct
            && lexicalCandidate.count >= 2
            && WordPlausibility.isWordLike(lexicalCandidate)
            && (AutoFixDecision.isCrossScriptConversion(original: word, candidate: best.candidate)
                || (spellChecker.mappedSpellingStatus(sourceWord, language: currentLanguage) == .misspelled
                    && mapper.convert(text: best.candidate, fromSourceID: best.targetID, toSourceID: source.id) == word))
        // Only a plausible source-language token can be an ordinary spelling typo.
        // Stripping physical layout keys (e.g. lzre. -> lzre -> lure) invents a different word.
        if config.spellingTypoGuardEnabled && Self.isLexicalToken(word)
            && (!verifiedLayoutWord || originalScore >= 0.5) {
            let typo = AutoFixDecision.spellingTypoGuardAssessment(original: word, candidate: best.candidate,
                language: currentLanguage, minWordLength: config.spellingTypoGuardMinimumLength,
                maxEditDistance: config.spellingTypoGuardMaximumDistance,
                isKnownCorrect: { !spellChecker.isMisspelled($0, language: $1) },
                suggestions: { spellChecker.guesses(for: $0, language: $1) })
            if typo.shouldSuppressAutoReplace { return result(.suggestSpelling(typo)) }
        }
        let adjustment = ProtectedLexiconPredictionScorer.adjustment(original: word,
            candidate: best.candidate, scoreCandidate: best.scoreCandidate, threshold: threshold)
        effectiveScore = adjustment.adjustedCandidateScore
        threshold = adjustment.adjustedThreshold
        let mixed = AutoFixMixedLanguagePolicy.decision(original: word, candidate: best.candidate,
            currentLanguage: currentLanguage, targetLanguage: best.targetLang,
            scoreOriginal: originalScore, scoreCandidate: effectiveScore, threshold: threshold, verifiedLayoutWord: verifiedLayoutWord)
        if case .skipAsIntentional = mixed { return result(.keep(.mixedLanguageIntentional)) }
        guard verifiedLayoutWord || AutoFixDecision.shouldReplace(scoreOriginal: originalScore,
            scoreCandidate: effectiveScore, threshold: threshold) else { return result(.uncertain) }
        guard hasCore else { return result(.uncertain) }
        guard Self.isPlausibleAutomaticTarget(lexicalCandidate, language: best.targetLang,
                                              spellChecker: spellChecker) else { return result(.uncertain) }
        return result(selection?.isAmbiguous == true ? .suggestLayout : .replace)
    }

    /// The system English dictionary accepts almost any two or three letters
    /// (`dg`, `y'f`), and a language score says nothing about spelling, so on
    /// their own they let `вп → dg` and `нєа, → y'f,` through. An automatic
    /// replacement must land on something that reads as a word; with only two
    /// letters, it must also be attested by the frequency or learned vocabulary.
    static func isPlausibleAutomaticTarget(
        _ candidate: String,
        language: String,
        spellChecker: SpellCheckingClient
    ) -> Bool {
        // An unplanned candidate still carries its edge punctuation (`роблю)`).
        let core = BufferedToken(rawText: candidate, keyCodes: []).core
        if spellChecker.isExplicitlyKnown(core, language: language) { return true }
        return core.filter(\.isLetter).count > 2 && WordPlausibility.isWordLike(core)
    }

    /// A word in neither dictionary that is still plainly typed in the wrong
    /// layout: what was typed is noise in its own language, and what it maps
    /// to reads as a word. Both language scores sit near zero for such words,
    /// so the absolute threshold never fires; the test is that the typed text
    /// scores as nothing while the mapped text scores clearly more.
    static func isUndictionariedLayoutSlip(
        source: String,
        candidate: String,
        scoreOriginal: Double,
        scoreCandidate: Double
    ) -> Bool {
        source.count >= 4
            && AutoFixDecision.isCrossScriptConversion(original: source, candidate: candidate)
            && WordPlausibility.isWordLike(candidate)
            // 0.03: correctly typed translit slang (`афтер`, 0.048) sits just above.
            && scoreOriginal <= 0.03
            && (scoreCandidate >= 3 * scoreOriginal + 0.01 || !WordPlausibility.isWordLike(source))
    }

    /// A short source token that is a real word in the current language yet
    /// maps to a common word of the target one (`ot → ще`, `ye → ну`). Alone it
    /// proves nothing either way, so inside a wrong-layout run it must not
    /// count as a contradiction that cuts the run in half.
    static func isAmbiguousShortSourceWord(
        _ word: String,
        candidate: String,
        targetLanguage: String,
        spellChecker: SpellCheckingClient
    ) -> Bool {
        let core = BufferedToken(rawText: word, keyCodes: []).core
        let mapped = BufferedToken(rawText: candidate, keyCodes: []).core
        return (2...3).contains(core.count)
            && core == word
            && AutoFixDecision.isCrossScriptConversion(original: core, candidate: mapped)
            && spellChecker.logFrequency(of: mapped, language: targetLanguage) >= 2
    }
    private static func isLexicalToken(_ word: String) -> Bool {
        let pieces = word.split(omittingEmptySubsequences: false, whereSeparator: { "-'’ʼ".contains($0) })
        return !pieces.isEmpty && pieces.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isLetter) }
    }

}
