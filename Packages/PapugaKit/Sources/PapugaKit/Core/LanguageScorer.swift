import Foundation

enum LanguageScorerAlgorithm: String, CaseIterable, Codable {
    case appleNL
    case ngram
    case cld3

    static var implementedCases: [LanguageScorerAlgorithm] {
        allCases.filter(\.isImplemented)
    }

    var title: String {
        switch self {
        case .appleNL: return "Локальний словник + мовна модель"
        case .ngram: return "Local n-gram (LREC 2010)"
        case .cld3: return "CLD3 (Google neural)"
        }
    }

    var description: String {
        switch self {
        case .appleNL:
            return "Локальні словники й n-gram модель; для інших мов — оцінка macOS."
        case .ngram:
            return "Маленька n-gram модель, навчена на UA/EN/RU. Точніше для коротких слів."
        case .cld3:
            return "Нейронна модель Google. Поки не доступно (заглушка)."
        }
    }

    var isImplemented: Bool {
        switch self {
        case .appleNL: return true
        case .ngram: return false
        case .cld3: return false
        }
    }

    var resolvedImplementation: LanguageScorerAlgorithm {
        isImplemented ? self : .appleNL
    }
}

protocol LanguageScorer {
    func score(_ text: String, expecting languageCode: String) -> Double
}

enum LanguageScorerFactory {
    static func make(_ algorithm: LanguageScorerAlgorithm) -> LanguageScorer {
        switch algorithm.resolvedImplementation {
        case .appleNL: return NGramScorer()
        case .ngram: return NGramScorer()
        case .cld3: return CLD3Scorer()
        }
    }
}
