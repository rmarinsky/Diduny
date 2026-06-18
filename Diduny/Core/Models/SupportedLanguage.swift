import Carbon.HIToolbox
import Foundation

struct SupportedLanguage: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }

    /// All languages supported by cloud transcription & translation (60 languages).
    static let cloudLanguages: [SupportedLanguage] = [
        SupportedLanguage(code: "af", name: "Afrikaans"),
        SupportedLanguage(code: "sq", name: "Albanian"),
        SupportedLanguage(code: "ar", name: "Arabic"),
        SupportedLanguage(code: "az", name: "Azerbaijani"),
        SupportedLanguage(code: "eu", name: "Basque"),
        SupportedLanguage(code: "be", name: "Belarusian"),
        SupportedLanguage(code: "bn", name: "Bengali"),
        SupportedLanguage(code: "bs", name: "Bosnian"),
        SupportedLanguage(code: "bg", name: "Bulgarian"),
        SupportedLanguage(code: "ca", name: "Catalan"),
        SupportedLanguage(code: "zh", name: "Chinese"),
        SupportedLanguage(code: "hr", name: "Croatian"),
        SupportedLanguage(code: "cs", name: "Czech"),
        SupportedLanguage(code: "da", name: "Danish"),
        SupportedLanguage(code: "nl", name: "Dutch"),
        SupportedLanguage(code: "en", name: "English"),
        SupportedLanguage(code: "et", name: "Estonian"),
        SupportedLanguage(code: "fi", name: "Finnish"),
        SupportedLanguage(code: "fr", name: "French"),
        SupportedLanguage(code: "gl", name: "Galician"),
        SupportedLanguage(code: "de", name: "German"),
        SupportedLanguage(code: "el", name: "Greek"),
        SupportedLanguage(code: "gu", name: "Gujarati"),
        SupportedLanguage(code: "he", name: "Hebrew"),
        SupportedLanguage(code: "hi", name: "Hindi"),
        SupportedLanguage(code: "hu", name: "Hungarian"),
        SupportedLanguage(code: "id", name: "Indonesian"),
        SupportedLanguage(code: "it", name: "Italian"),
        SupportedLanguage(code: "ja", name: "Japanese"),
        SupportedLanguage(code: "kn", name: "Kannada"),
        SupportedLanguage(code: "kk", name: "Kazakh"),
        SupportedLanguage(code: "ko", name: "Korean"),
        SupportedLanguage(code: "lv", name: "Latvian"),
        SupportedLanguage(code: "lt", name: "Lithuanian"),
        SupportedLanguage(code: "mk", name: "Macedonian"),
        SupportedLanguage(code: "ms", name: "Malay"),
        SupportedLanguage(code: "ml", name: "Malayalam"),
        SupportedLanguage(code: "mr", name: "Marathi"),
        SupportedLanguage(code: "no", name: "Norwegian"),
        SupportedLanguage(code: "fa", name: "Persian"),
        SupportedLanguage(code: "pl", name: "Polish"),
        SupportedLanguage(code: "pt", name: "Portuguese"),
        SupportedLanguage(code: "pa", name: "Punjabi"),
        SupportedLanguage(code: "ro", name: "Romanian"),
        SupportedLanguage(code: "ru", name: "Russian"),
        SupportedLanguage(code: "sr", name: "Serbian"),
        SupportedLanguage(code: "sk", name: "Slovak"),
        SupportedLanguage(code: "sl", name: "Slovenian"),
        SupportedLanguage(code: "es", name: "Spanish"),
        SupportedLanguage(code: "sw", name: "Swahili"),
        SupportedLanguage(code: "sv", name: "Swedish"),
        SupportedLanguage(code: "tl", name: "Tagalog"),
        SupportedLanguage(code: "ta", name: "Tamil"),
        SupportedLanguage(code: "te", name: "Telugu"),
        SupportedLanguage(code: "th", name: "Thai"),
        SupportedLanguage(code: "tr", name: "Turkish"),
        SupportedLanguage(code: "uk", name: "Ukrainian"),
        SupportedLanguage(code: "ur", name: "Urdu"),
        SupportedLanguage(code: "vi", name: "Vietnamese"),
        SupportedLanguage(code: "cy", name: "Welsh"),
    ]

    /// Languages supported by local Whisper models (subset).
    static let whisperLanguages: [SupportedLanguage] = [
        SupportedLanguage(code: "auto", name: "Auto-detect"),
        SupportedLanguage(code: "af", name: "Afrikaans"),
        SupportedLanguage(code: "ar", name: "Arabic"),
        SupportedLanguage(code: "be", name: "Belarusian"),
        SupportedLanguage(code: "bg", name: "Bulgarian"),
        SupportedLanguage(code: "bn", name: "Bengali"),
        SupportedLanguage(code: "ca", name: "Catalan"),
        SupportedLanguage(code: "cs", name: "Czech"),
        SupportedLanguage(code: "cy", name: "Welsh"),
        SupportedLanguage(code: "da", name: "Danish"),
        SupportedLanguage(code: "de", name: "German"),
        SupportedLanguage(code: "el", name: "Greek"),
        SupportedLanguage(code: "en", name: "English"),
        SupportedLanguage(code: "es", name: "Spanish"),
        SupportedLanguage(code: "et", name: "Estonian"),
        SupportedLanguage(code: "fa", name: "Persian"),
        SupportedLanguage(code: "fi", name: "Finnish"),
        SupportedLanguage(code: "fr", name: "French"),
        SupportedLanguage(code: "gl", name: "Galician"),
        SupportedLanguage(code: "he", name: "Hebrew"),
        SupportedLanguage(code: "hi", name: "Hindi"),
        SupportedLanguage(code: "hr", name: "Croatian"),
        SupportedLanguage(code: "hu", name: "Hungarian"),
        SupportedLanguage(code: "id", name: "Indonesian"),
        SupportedLanguage(code: "it", name: "Italian"),
        SupportedLanguage(code: "ja", name: "Japanese"),
        SupportedLanguage(code: "kk", name: "Kazakh"),
        SupportedLanguage(code: "ko", name: "Korean"),
        SupportedLanguage(code: "lt", name: "Lithuanian"),
        SupportedLanguage(code: "lv", name: "Latvian"),
        SupportedLanguage(code: "mk", name: "Macedonian"),
        SupportedLanguage(code: "ml", name: "Malayalam"),
        SupportedLanguage(code: "mr", name: "Marathi"),
        SupportedLanguage(code: "ms", name: "Malay"),
        SupportedLanguage(code: "nl", name: "Dutch"),
        SupportedLanguage(code: "no", name: "Norwegian"),
        SupportedLanguage(code: "pl", name: "Polish"),
        SupportedLanguage(code: "pt", name: "Portuguese"),
        SupportedLanguage(code: "ro", name: "Romanian"),
        SupportedLanguage(code: "ru", name: "Russian"),
        SupportedLanguage(code: "sk", name: "Slovak"),
        SupportedLanguage(code: "sl", name: "Slovenian"),
        SupportedLanguage(code: "sr", name: "Serbian"),
        SupportedLanguage(code: "sv", name: "Swedish"),
        SupportedLanguage(code: "sw", name: "Swahili"),
        SupportedLanguage(code: "ta", name: "Tamil"),
        SupportedLanguage(code: "te", name: "Telugu"),
        SupportedLanguage(code: "th", name: "Thai"),
        SupportedLanguage(code: "tl", name: "Tagalog"),
        SupportedLanguage(code: "tr", name: "Turkish"),
        SupportedLanguage(code: "uk", name: "Ukrainian"),
        SupportedLanguage(code: "ur", name: "Urdu"),
        SupportedLanguage(code: "vi", name: "Vietnamese"),
        SupportedLanguage(code: "zh", name: "Chinese"),
    ]

    // Legacy alias for backward compatibility
    static let allLanguages: [SupportedLanguage] = cloudLanguages

    static func language(for code: String) -> SupportedLanguage? {
        guard let normalized = normalizedCode(code) else { return nil }
        return cloudLanguages.first(where: { $0.code == normalized })
    }

    static func normalizedCode(_ code: String?, allowAuto: Bool = false) -> String? {
        guard let code else { return nil }

        let trimmed = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !trimmed.isEmpty else { return nil }
        if allowAuto, trimmed == "auto" { return trimmed }

        let languageCode = String(trimmed.split(separator: "-").first ?? Substring(trimmed))
        let aliases: [String: String] = [
            "ua": "uk",
            "iw": "he",
            "in": "id",
            "nb": "no",
            "nn": "no",
            "cmn": "zh",
            "yue": "zh"
        ]
        let normalized = aliases[languageCode] ?? languageCode
        return cloudLanguages.contains(where: { $0.code == normalized }) ? normalized : nil
    }
}

struct TranslationLanguagePair: Identifiable, Codable, Hashable {
    let id: String
    let languageA: String
    let languageB: String

    init(id: String? = nil, languageA: String, languageB: String) {
        let normalizedA = SupportedLanguage.normalizedCode(languageA) ?? "en"
        let normalizedB = SupportedLanguage.normalizedCode(languageB) ?? "uk"
        self.languageA = normalizedA
        self.languageB = normalizedB == normalizedA ? Self.fallbackLanguage(opposite: normalizedA) : normalizedB
        self.id = id?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "\(self.languageA)-\(self.languageB)"
    }

    var codes: [String] {
        [languageA, languageB]
    }

    var displayLabel: String {
        "\(languageA.uppercased()) ⇄ \(languageB.uppercased())"
    }

    func contains(_ languageCode: String?) -> Bool {
        guard let normalized = SupportedLanguage.normalizedCode(languageCode) else { return false }
        return languageA == normalized || languageB == normalized
    }

    func opposite(of languageCode: String?) -> String? {
        guard let normalized = SupportedLanguage.normalizedCode(languageCode) else { return nil }
        if normalized == languageA { return languageB }
        if normalized == languageB { return languageA }
        return nil
    }

    static let defaultPair = TranslationLanguagePair(languageA: "en", languageB: "uk")

    private static func fallbackLanguage(opposite language: String) -> String {
        language == "en" ? "uk" : "en"
    }
}

struct KeyboardLanguageDetector {
    struct DetectedLanguage: Identifiable, Hashable {
        let code: String
        let sourceName: String
        let sourceID: String

        var id: String {
            "\(sourceID):\(code)"
        }
    }

    static func detectedLanguages() -> [DetectedLanguage] {
        selectableInputSources().flatMap { source -> [DetectedLanguage] in
            let id = stringProperty(source, key: kTISPropertyInputSourceID) ?? ""
            let name = stringProperty(source, key: kTISPropertyLocalizedName) ?? id
            let languages = stringArrayProperty(source, key: kTISPropertyInputSourceLanguages)
            return languageCodes(
                inputSourceLanguages: languages,
                inputSourceID: id,
                localizedName: name
            ).map { DetectedLanguage(code: $0, sourceName: name, sourceID: id) }
        }
        .deduplicatedByCode()
    }

    static func detectedLanguageCodes() -> [String] {
        detectedLanguages().map(\.code)
    }

    static func currentLanguageCode() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let id = stringProperty(source, key: kTISPropertyInputSourceID) ?? ""
        let name = stringProperty(source, key: kTISPropertyLocalizedName) ?? id
        let languages = stringArrayProperty(source, key: kTISPropertyInputSourceLanguages)
        return languageCodes(inputSourceLanguages: languages, inputSourceID: id, localizedName: name).first
    }

    static func languageCodes(
        inputSourceLanguages: [String],
        inputSourceID: String,
        localizedName: String
    ) -> [String] {
        let languageCodesFromProperty = SupportedLanguageCodes.normalized(inputSourceLanguages)
        let fallbackCodes = fallbackLanguageCodes(inputSourceID: inputSourceID, localizedName: localizedName)

        if languageCodesFromProperty.count > 2, !fallbackCodes.isEmpty {
            return fallbackCodes
        }

        if !languageCodesFromProperty.isEmpty {
            return languageCodesFromProperty
        }

        return fallbackCodes
    }

    private static func fallbackLanguageCodes(inputSourceID: String, localizedName: String) -> [String] {
        let fallbackSource = "\(inputSourceID) \(localizedName)".lowercased()
        let fragments: [(needle: String, code: String)] = [
            ("ukrain", "uk"),
            (".us", "en"),
            ("u.s.", "en"),
            ("abc", "en"),
            ("british", "en"),
            ("english", "en"),
            ("german", "de"),
            ("deutsch", "de"),
            ("french", "fr"),
            ("francais", "fr"),
            ("spanish", "es"),
            ("polish", "pl"),
            ("italian", "it"),
            ("portuguese", "pt"),
            ("chinese", "zh"),
            ("japanese", "ja"),
            ("korean", "ko")
        ]

        guard let match = fragments.first(where: { fallbackSource.contains($0.needle) }) else {
            return []
        }
        return [match.code]
    }

    private static func selectableInputSources() -> [TISInputSource] {
        let conditions = [
            kTISPropertyInputSourceCategory!: kTISCategoryKeyboardInputSource!,
            kTISPropertyInputSourceIsSelectCapable!: true
        ] as CFDictionary

        return TISCreateInputSourceList(conditions, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    private static func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func stringArrayProperty(_ source: TISInputSource, key: CFString) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
        return array as? [String] ?? []
    }
}

private enum SupportedLanguageCodes {
    static func normalized(_ codes: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for code in codes {
            guard let normalized = SupportedLanguage.normalizedCode(code),
                  seen.insert(normalized).inserted
            else { continue }
            result.append(normalized)
        }
        return result
    }
}

private extension Array where Element == KeyboardLanguageDetector.DetectedLanguage {
    func deduplicatedByCode() -> [Element] {
        var result: [Element] = []
        var seen = Set<String>()
        for language in self where seen.insert(language.code).inserted {
            result.append(language)
        }
        return result
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
