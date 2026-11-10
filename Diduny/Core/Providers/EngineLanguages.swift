import Foundation

/// One language in an engine's display list.
struct EngineLanguage: Hashable, Sendable {
    /// The app's code (ISO 639-1 where one exists): used to match "Your languages".
    let code: String
    /// The code as the vendor prints it (ElevenLabs ISO 639-3, Whisper `jw`); used for the name.
    let vendorCode: String

    init(_ code: String, vendorCode: String? = nil) {
        self.code = code
        self.vendorCode = vendorCode ?? code
    }
}

struct EngineLanguageGroup: Equatable, Sendable {
    /// nil = an unnamed group.
    let title: String?
    let languages: [EngineLanguage]
}

/// What an engine lists in the language popup. Never gates a recording (ADR-0012 D1).
enum EngineLanguageList: Equatable, Sendable {
    case groups([EngineLanguageGroup])
    /// Set in macOS: the OS decides at run time, there is no list.
    case system

    var languages: [EngineLanguage] {
        switch self {
        case let .groups(groups): groups.flatMap(\.languages)
        case .system: []
        }
    }

    /// nil for `.system`.
    var count: Int? {
        switch self {
        case .groups: languages.count
        case .system: nil
        }
    }

    /// The listed languages that are in `yourLanguages`, matched by code ("zh-Hans" matches Mandarin), in list order.
    func marked(by yourLanguages: [String]) -> [EngineLanguage] {
        let codes = Set(yourLanguages.compactMap { code in
            code.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init)
        })
        return languages.filter { codes.contains($0.code) }
    }
}

/// Language data per engine (design 03 2.2, `translation-support.md`). Lists keep the prototype order
/// (alphabetical by English name); the popup sorts for the user's locale.
enum EngineLanguages {
    /// Diduny Cloud (Soniox): the 60 app languages.
    static let didunyCloud = EngineLanguageList.groups([
        EngineLanguageGroup(title: nil, languages: SupportedLanguage.cloudLanguages.map { EngineLanguage($0.code) })
    ])

    /// ElevenLabs ISO 639-3 code to the app's code (`docs/research/elevenlabs/08-models-and-languages.md`).
    /// Mandarin matches Chinese and Filipino matches Tagalog; codes without an ISO 639-1 code stay as printed.
    static let elevenLabsCodes: [String: String] = [
        "bel": "be", "bos": "bs", "bul": "bg", "cat": "ca", "hrv": "hr", "ces": "cs", "dan": "da", "nld": "nl",
        "eng": "en", "est": "et", "fin": "fi", "fra": "fr", "glg": "gl", "deu": "de", "ell": "el", "hun": "hu",
        "isl": "is", "ind": "id", "ita": "it", "jpn": "ja", "kan": "kn", "lav": "lv", "mkd": "mk", "msa": "ms",
        "mal": "ml", "nor": "no", "pol": "pl", "por": "pt", "ron": "ro", "rus": "ru", "slk": "sk", "spa": "es",
        "swe": "sv", "tur": "tr", "ukr": "uk", "vie": "vi",
        "hye": "hy", "aze": "az", "ben": "bn", "yue": "yue", "fil": "tl", "kat": "ka", "guj": "gu", "hin": "hi",
        "kaz": "kk", "lit": "lt", "mlt": "mt", "cmn": "zh", "mar": "mr", "nep": "ne", "ori": "or", "fas": "fa",
        "srp": "sr", "slv": "sl", "swa": "sw", "tam": "ta", "tel": "te",
        "afr": "af", "ara": "ar", "asm": "as", "ast": "ast", "mya": "my", "hau": "ha", "heb": "he", "jav": "jv",
        "kor": "ko", "kir": "ky", "ltz": "lb", "mri": "mi", "oci": "oc", "pan": "pa", "tgk": "tg", "tha": "th",
        "uzb": "uz", "cym": "cy",
        "amh": "am", "lug": "lg", "ibo": "ig", "gle": "ga", "khm": "km", "kur": "ku", "lao": "lo", "mon": "mn",
        "nso": "nso", "pus": "ps", "sna": "sn", "snd": "sd", "sin": "si", "som": "so", "urd": "ur", "wol": "wo",
        "xho": "xh", "yor": "yo", "zul": "zu"
    ]

    /// ElevenLabs Scribe v2: 94 languages in the four accuracy tiers ElevenLabs publishes.
    static let elevenLabs = EngineLanguageList.groups([
        elevenLabsGroup(String(localized: "Excellent accuracy"), [
            "bel", "bos", "bul", "cat", "hrv", "ces", "dan", "nld", "eng", "est", "fin", "fra", "glg", "deu", "ell",
            "hun", "isl", "ind", "ita", "jpn", "kan", "lav", "mkd", "msa", "mal", "nor", "pol", "por", "ron", "rus",
            "slk", "spa", "swe", "tur", "ukr", "vie"
        ]),
        elevenLabsGroup(String(localized: "High accuracy"), [
            "hye", "aze", "ben", "yue", "fil", "kat", "guj", "hin", "kaz", "lit", "mlt", "cmn", "mar", "nep", "ori",
            "fas", "srp", "slv", "swa", "tam", "tel"
        ]),
        elevenLabsGroup(String(localized: "Good accuracy"), [
            "afr", "ara", "asm", "ast", "mya", "hau", "heb", "jav", "kor", "kir", "ltz", "mri", "oci", "pan", "tgk",
            "tha", "uzb", "cym"
        ]),
        elevenLabsGroup(String(localized: "Moderate accuracy"), [
            "amh", "lug", "ibo", "gle", "khm", "kur", "lao", "mon", "nso", "pus", "sna", "snd", "sin", "som", "urd",
            "wol", "xho", "yor", "zul"
        ])
    ])

    /// Whisper: the 100 languages of OpenAI `whisper/tokenizer.py`. Javanese is `jw` there, `jv` in ISO 639-1.
    /// Display only: the Whisper source-language picker keeps its 53 (`SupportedLanguage.whisperLanguages`).
    static let whisper = EngineLanguageList.groups([
        EngineLanguageGroup(title: nil, languages: [
            "af", "sq", "am", "ar", "hy", "as", "az", "ba", "eu", "be", "bn", "bs", "br", "bg", "my", "yue", "ca",
            "zh", "hr", "cs", "da", "nl", "en", "et", "fo", "fi", "fr", "gl", "ka", "de", "el", "gu", "ht", "ha",
            "haw", "he", "hi", "hu", "is", "id", "it", "ja"
        ].map { EngineLanguage($0) } + [EngineLanguage("jv", vendorCode: "jw")] + [
            "kn", "kk", "km", "ko", "lo", "la", "lv", "ln", "lt", "lb", "mk", "mg", "ms", "ml", "mt", "mi", "mr",
            "mn", "ne", "no", "nn", "oc", "ps", "fa", "pl", "pt", "pa", "ro", "ru", "sa", "sr", "sn", "sd", "si",
            "sk", "sl", "so", "es", "su", "sw", "sv", "tl", "tg", "ta", "tt", "te", "th", "bo", "tr", "tk", "uk",
            "ur", "uz", "vi", "cy", "yi", "yo"
        ].map { EngineLanguage($0) })
    ])

    /// Parakeet V3: the 25 languages of the `nvidia/parakeet-tdt-0.6b-v3` model card.
    static let parakeet = EngineLanguageList.groups([
        EngineLanguageGroup(title: nil, languages: [
            "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl",
            "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk"
        ].map { EngineLanguage($0) })
    ])

    /// English names for listed codes outside the 60 app languages, used when the OS has no name.
    /// `SupportedLanguage` cannot name them (`normalizedCode` returns nil outside the 60).
    static let fallbackNames: [String: String] = [
        "am": "Amharic", "as": "Assamese", "ast": "Asturian", "ba": "Bashkir", "bo": "Tibetan", "br": "Breton",
        "fo": "Faroese", "ga": "Irish", "ha": "Hausa", "haw": "Hawaiian", "ht": "Haitian Creole", "hy": "Armenian",
        "ig": "Igbo", "is": "Icelandic", "jv": "Javanese", "ka": "Georgian", "km": "Khmer", "ku": "Kurdish",
        "ky": "Kyrgyz", "la": "Latin", "lb": "Luxembourgish", "lg": "Ganda", "ln": "Lingala", "lo": "Lao",
        "mg": "Malagasy", "mi": "Maori", "mn": "Mongolian", "mt": "Maltese", "my": "Burmese", "ne": "Nepali",
        "nn": "Norwegian Nynorsk", "nso": "Northern Sotho", "oc": "Occitan", "or": "Odia", "ps": "Pashto",
        "sa": "Sanskrit", "sd": "Sindhi", "si": "Sinhala", "sn": "Shona", "so": "Somali", "su": "Sundanese",
        "tg": "Tajik", "tk": "Turkmen", "tt": "Tatar", "uz": "Uzbek", "wo": "Wolof", "xh": "Xhosa", "yi": "Yiddish",
        "yo": "Yoruba", "yue": "Cantonese", "zu": "Zulu"
    ]

    /// The app's UI language, as `SupportedLanguage.name` uses.
    static var appLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// Localised name from the code; never depends on `SupportedLanguage.normalizedCode`.
    static func name(of language: EngineLanguage, locale: Locale = appLocale) -> String {
        locale.localizedString(forLanguageCode: language.vendorCode)
            ?? locale.localizedString(forLanguageCode: language.code)
            ?? fallbackNames[language.code]
            ?? SupportedLanguage.cloudLanguages.first { $0.code == language.code }?.name
            ?? language.code
    }

    private static func elevenLabsGroup(_ title: String, _ iso639_3: [String]) -> EngineLanguageGroup {
        EngineLanguageGroup(title: title, languages: iso639_3.map { EngineLanguage(elevenLabsCodes[$0] ?? $0, vendorCode: $0) })
    }
}
