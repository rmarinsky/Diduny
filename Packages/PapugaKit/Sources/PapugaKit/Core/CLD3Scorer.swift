import Foundation

struct CLD3Scorer: LanguageScorer {
    func score(_ text: String, expecting languageCode: String) -> Double {
        // Stub: integrating https://github.com/google/cld3 requires vendoring the
        // C++ static lib + Swift bridge for arm64+x86_64. Falls back to AppleNLScorer
        // until that work lands, so the algorithm picker stays functional.
        return AppleNLScorer().score(text, expecting: languageCode)
    }
}
