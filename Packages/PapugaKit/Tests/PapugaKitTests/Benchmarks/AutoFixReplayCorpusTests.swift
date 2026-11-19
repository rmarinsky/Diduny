import Carbon.HIToolbox
import XCTest
@testable import PapugaKit

/// Replays this Mac's own correction history through the production evaluator
/// and run verdict. Manual hotkey corrections are misses AutoFix should have
/// caught; automatic ones are fixes that must keep working. Reads the live
/// `replacement-history.jsonl`; nothing private is committed. Gated:
///
///   TEST_RUNNER_PAPUGA_REPLAY=1 xcodebuild test -project papuga.xcodeproj \
///     -scheme papuga -destination 'platform=macOS' \
///     -only-testing:papugaTests/AutoFixReplayCorpusTests
///
/// Editor safety gates (editing guard, target validation) are not replayed —
/// this measures detection only.
final class AutoFixReplayCorpusTests: XCTestCase {
    private func p(_ line: String) { print("REPLAY| \(line)") }

    func test_replayCorrectionHistory() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPUGA_REPLAY"] == "1",
                          "set PAPUGA_REPLAY=1 to replay the local correction history")
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("papuga/replacement-history.jsonl")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap {
            try? decoder.decode(ReplacementHistoryEntry.self, from: Data($0.utf8))
        }
        // The personal model learns from these very entries; replaying with it
        // loaded would grade the engine on its own answer key.
        PersonalLayoutModel.shared.replaceHistory([])

        let mapper = CharacterMapper()
        let checker = HybridSpellChecker.production()
        // The frequency indexes load on a background queue; judging before
        // they land measures a state production only has for its first second.
        let deadline = Date().addingTimeInterval(30)
        while !checker.indexedLanguages.isSuperset(of: ["uk", "en"]), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let scorer = LanguageScorerFactory.make(.appleNL)
        let evaluator = AutoFixWordEvaluator(mapper: mapper, spellChecker: checker, scorer: scorer)
        var sources: [String: InputSourceInfo] = [:]
        func source(_ id: String) -> InputSourceInfo? {
            if let cached = sources[id] { return cached }
            let list = TISCreateInputSourceList([kTISPropertyInputSourceID!: id] as CFDictionary, true)
                .takeRetainedValue() as? [TISInputSource]
            guard let tis = list?.first else { return nil }
            let info = InputSourceInfo(id: id, name: id, source: tis)
            sources[id] = info
            return info
        }

        var totals: [String: [String: Int]] = [:]
        for entry in entries where entry.kind == .manualSwitch || entry.kind == .autoFixApplied {
            guard let targetID = entry.targetLayoutID, let sourceID = entry.sourceLayoutID,
                  let from = source(sourceID), let to = source(targetID),
                  entry.original != entry.converted else { continue }
            let words = entry.original.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            let fromLang = AutoFixDecision.languageHintForLayoutID(from.id)
            let toLang = AutoFixDecision.languageHintForLayoutID(to.id)

            var evidence: [LayoutIncidentToken.Evidence] = []
            var candidates: [String] = []
            var dispositions: [String] = []
            var previous: String?
            for word in words {
                let result = evaluator.evaluate(word, source: from, targets: [to],
                                                configuration: .init(), previousWord: previous)
                previous = word
                candidates.append(result.selection?.best.candidate ?? word)
                dispositions.append(String(format: "\(result.disposition) %.2f>%.2f",
                                           result.scoreOriginal, result.selection?.best.scoreCandidate ?? -1))
                switch result.disposition {
                case .replace: evidence.append(.strong)
                case .sourceWord:
                    evidence.append(AutoFixWordEvaluator.isAmbiguousShortSourceWord(
                        word, candidate: result.selection?.best.candidate ?? word,
                        targetLanguage: toLang, spellChecker: checker) ? .neutral : .contradiction)
                default: evidence.append(.neutral)
                }
            }
            var count = words.count
            while count > 0, evidence[count - 1] == .contradiction { count -= 1 }
            var detail = ""
            let verdict: String
            if count == 0 {
                verdict = "discard"
            } else if words.count == 1 {
                verdict = evidence[0] == .strong ? "replace" : "discard"
            } else {
                let original = words[..<count].joined(separator: " ")
                let candidate = candidates[..<count].joined(separator: " ")
                let judged = evidence[..<count]
                let scoreOriginal = scorer.score(original, expecting: fromLang)
                let scoreCandidate = scorer.score(candidate, expecting: toLang)
                detail = String(format: " margin=%.2f strong=%d/%d contradiction=%@",
                                scoreCandidate - scoreOriginal, judged.filter { $0 == .strong }.count,
                                judged.count, judged.contains(.contradiction) ? "y" : "n")
                let decision = LayoutIncidentTracker.runVerdict(
                    scoreOriginal: scoreOriginal,
                    scoreCandidate: scoreCandidate,
                    threshold: AutoFixWordEvaluator.Configuration().threshold,
                    proposalWindow: 0.22,
                    hasContradiction: judged.contains(.contradiction),
                    hasUnanimousDictionarySupport: judged.allSatisfy { $0 == .strong },
                    hasStrongEvidence: judged.contains(.strong),
                    isDictionaryBackedRun: judged.count >= 2 && judged.contains(.strong)
                        && zip(words, judged).allSatisfy { word, evidence in
                            evidence == .strong || (evidence == .neutral
                                && BufferedToken(rawText: word, keyCodes: []).core.count <= 3)
                        }
                )
                verdict = count < words.count && decision == .replace ? "replace_partial" : "\(decision)"
            }
            totals[entry.kind.rawValue, default: [:]][verdict, default: 0] += 1
            if verdict != "replace" {
                p("\(entry.kind.rawValue) \(verdict) '\(entry.original)' -> '\(entry.converted)'\(detail) \(dispositions)")
            }
        }
        for (kind, counts) in totals.sorted(by: { $0.key < $1.key }) {
            let total = counts.values.reduce(0, +)
            p("TOTAL \(kind) n=\(total) \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
    }

    /// What the automatic spelling class would have changed among the words
    /// Papuga recorded as mistakes. Every line is a word that gets rewritten
    /// without asking — read them all before loosening `NarrowTypoCorrector`.
    func test_replayNarrowTypoCorrections() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPUGA_REPLAY"] == "1",
                          "set PAPUGA_REPLAY=1 to replay the local mistake observations")
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("papuga/mistake-observations.jsonl")
        var words: [String: Set<String>] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let source = object["source"] as? String,
                  let language = object["language"] as? String ?? object["sourceLanguage"] as? String
            else { continue }
            words[language, default: []].insert(source)
        }
        let checker = HybridSpellChecker.production()
        let deadline = Date().addingTimeInterval(30)
        while !checker.indexedLanguages.isSuperset(of: ["uk", "en"]), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let mapper = CharacterMapper()
        let layouts = ["uk": "com.apple.keylayout.Ukrainian-PC", "en": "com.apple.keylayout.US"]
        for (language, sources) in words.sorted(by: { $0.key < $1.key }) {
            guard let layoutID = layouts[language],
                  let list = TISCreateInputSourceList([kTISPropertyInputSourceID!: layoutID] as CFDictionary, true)
                    .takeRetainedValue() as? [TISInputSource], let tis = list.first else { continue }
            mapper.buildMap(for: tis, sourceID: layoutID)
            var fixed = 0
            for word in sources.sorted() {
                guard let correction = NarrowTypoCorrector.correction(for: word, language: language,
                    spellChecker: checker, keyCode: { mapper.mapping(for: $0, sourceID: layoutID)?.keyCode })
                else { continue }
                fixed += 1
                p("TYPO \(language) \(word) -> \(correction)")
            }
            p("TYPO TOTAL \(language) fixed=\(fixed) of \(sources.count)")
        }
    }

    /// The false-positive side: every word Papuga recorded as a mistake was
    /// typed in the RIGHT layout (slang, jargon, typos). None of them may be
    /// converted to the other layout.
    func test_replayCorrectLayoutWordsAreNotConverted() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPUGA_REPLAY"] == "1",
                          "set PAPUGA_REPLAY=1 to replay the local mistake observations")
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("papuga/mistake-observations.jsonl")
        var words: [String: Set<String>] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let source = object["source"] as? String, let language = object["language"] as? String
            else { continue }
            words[language, default: []].insert(source)
        }
        PersonalLayoutModel.shared.replaceHistory([])
        let checker = HybridSpellChecker.production()
        let deadline = Date().addingTimeInterval(30)
        while !checker.indexedLanguages.isSuperset(of: ["uk", "en"]), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let evaluator = AutoFixWordEvaluator(mapper: CharacterMapper(), spellChecker: checker,
                                             scorer: LanguageScorerFactory.make(.appleNL))
        func source(_ id: String) -> InputSourceInfo? {
            let list = TISCreateInputSourceList([kTISPropertyInputSourceID!: id] as CFDictionary, true)
                .takeRetainedValue() as? [TISInputSource]
            return list?.first.map { InputSourceInfo(id: id, name: id, source: $0) }
        }
        guard let uk = source("com.apple.keylayout.Ukrainian-PC"), let en = source("com.apple.keylayout.US") else { return }
        for (language, from, to) in [("uk", uk, en), ("en", en, uk)] {
            var converted = 0
            for word in (words[language] ?? []).sorted() {
                let result = evaluator.evaluate(word, source: from, targets: [to], configuration: .init())
                guard let replacement = result.replacement else { continue }
                converted += 1
                p(String(format: "FALSEFIX \(language) \(word) -> \(replacement.candidate) %.3f>%.3f",
                         result.scoreOriginal, replacement.scoreCandidate))
            }
            p("FALSEFIX TOTAL \(language) converted=\(converted) of \(words[language]?.count ?? 0)")
        }
    }
}
