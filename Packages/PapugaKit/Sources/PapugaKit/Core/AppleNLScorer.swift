import Foundation
import NaturalLanguage

/// Reuses a single `NLLanguageRecognizer` across calls (reset between uses) instead of allocating a
/// fresh one per word. The recognizer is stateful and not thread-safe, but all scoring runs on the
/// main actor (AutoFixController) / single-threaded tests, so a single instance is safe here.
/// Reference type so the cached recognizer survives; cache the scorer itself to get the benefit.
final class AppleNLScorer: LanguageScorer {
    private let recognizer = NLLanguageRecognizer()

    func score(_ text: String, expecting languageCode: String) -> Double {
        guard !text.isEmpty else { return 0 }
        recognizer.reset()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let target = NLLanguage(languageCode)
        return hypotheses[target] ?? 0
    }
}
