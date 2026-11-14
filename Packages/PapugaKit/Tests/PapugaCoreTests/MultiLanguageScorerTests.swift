import XCTest
@testable import PapugaCore

/// Verifies that the chosen LanguageScorer correctly favours the expected language
/// for short, real-world phrases across the most common European languages.
/// Only AppleNL is implemented. Factory fallback behavior is covered by LanguageScorerTests.
final class MultiLanguageScorerTests: XCTestCase {
    private struct ScorerCase {
        let label: String
        let text: String
        let preferred: String
        let against: [String]
    }

    private static let cases: [ScorerCase] = [
        ScorerCase(label: "Ukrainian", text: "Україна та Київ — столиця",
                   preferred: "uk", against: ["en", "ru"]),
        ScorerCase(label: "Russian", text: "Привет мир, как дела",
                   preferred: "ru", against: ["en", "uk"]),
        ScorerCase(label: "English", text: "The quick brown fox jumps over the lazy dog",
                   preferred: "en", against: ["de", "fr", "es"]),
        ScorerCase(label: "German",  text: "Guten Tag, wie geht es dir heute",
                   preferred: "de", against: ["en", "nl"]),
        ScorerCase(label: "French",  text: "Bonjour, comment allez-vous aujourd'hui",
                   preferred: "fr", against: ["en", "es", "it"]),
        ScorerCase(label: "Spanish", text: "Hola, ¿cómo estás hoy mi amigo",
                   preferred: "es", against: ["en", "it", "pt"]),
        ScorerCase(label: "Italian", text: "Buongiorno, come stai oggi mio amico",
                   preferred: "it", against: ["en", "es", "fr"]),
        ScorerCase(label: "Polish",  text: "Dzień dobry, jak się masz dzisiaj",
                   preferred: "pl", against: ["en", "cs", "ru"]),
        ScorerCase(label: "Portuguese", text: "Bom dia, como você está hoje meu amigo",
                   preferred: "pt", against: ["en", "es", "it"]),
        ScorerCase(label: "Turkish", text: "Merhaba, bugün nasılsın arkadaşım",
                   preferred: "tr", against: ["en", "de"]),
        ScorerCase(label: "Dutch",   text: "Goedemorgen, hoe gaat het met je vandaag",
                   preferred: "nl", against: ["en", "de"]),
        ScorerCase(label: "Czech",   text: "Dobrý den, jak se máš dnes",
                   preferred: "cs", against: ["en", "pl", "sk"])
    ]

    private func runCases(algorithm: LanguageScorerAlgorithm) {
        let scorer = LanguageScorerFactory.make(algorithm)
        for tc in Self.cases {
            let preferredScore = scorer.score(tc.text, expecting: tc.preferred)
            for other in tc.against {
                let otherScore = scorer.score(tc.text, expecting: other)
                XCTAssertGreaterThan(
                    preferredScore,
                    otherScore,
                    "[\(algorithm.rawValue)] \(tc.label): expected '\(tc.preferred)' (\(preferredScore)) > '\(other)' (\(otherScore)) for '\(tc.text)'"
                )
            }
        }
    }

    func test_all_languages_with_appleNL() {
        runCases(algorithm: .appleNL)
    }

}
