import Foundation

struct SupportedLanguage: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }

    static let allLanguages: [SupportedLanguage] = [
        SupportedLanguage(code: "uk", name: "Ukrainian"),
        SupportedLanguage(code: "en", name: "English"),
        SupportedLanguage(code: "ro", name: "Romanian"),
        SupportedLanguage(code: "es", name: "Spanish"),
        SupportedLanguage(code: "de", name: "German"),
        SupportedLanguage(code: "fr", name: "French"),
        SupportedLanguage(code: "pl", name: "Polish"),
        SupportedLanguage(code: "it", name: "Italian"),
        SupportedLanguage(code: "pt", name: "Portuguese"),
        SupportedLanguage(code: "ja", name: "Japanese"),
        SupportedLanguage(code: "zh", name: "Chinese"),
        SupportedLanguage(code: "ko", name: "Korean"),
        SupportedLanguage(code: "ru", name: "Russian"),
    ]

    static func language(for code: String) -> SupportedLanguage? {
        allLanguages.first(where: { $0.code == code })
    }
}
