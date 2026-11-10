import Foundation

enum VoiceTranslationCommandPosition: String, CaseIterable, Identifiable {
    case startAndEnd
    case endOnly
    /// The start and end, plus a command phrase between other words (05 §2.3).
    case anywhere

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .startAndEnd: String(localized: "At the start and end")
        case .endOnly: String(localized: "At the end")
        case .anywhere: String(localized: "Anywhere")
        }
    }
}

enum VoiceTranslationCommandTargets: String, CaseIterable, Identifiable {
    case anySupported
    case translationPairsOnly

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .anySupported: String(localized: "Any supported language")
        case .translationPairsOnly: String(localized: "Only my translation pairs")
        }
    }
}

/// A spoken "translate into X" said as the first or last words of a dictation.
/// Only the head and the tail of the text are checked, except with `.anywhere`:
/// then a phrase that starts with a verb ("translate into Polish") is also a
/// command between other words, unless it follows "to" ("need to translate...").
struct VoiceTranslationCommand: Equatable {
    enum Position: Equatable {
        case leading
        case trailing
        case middle
    }

    let targetLanguage: String
    /// The command words exactly as spoken.
    let commandText: String
    /// The dictation with the command words removed.
    let remainingText: String
    let position: Position

    var output: DictationOutput {
        .translation(targetLanguage: targetLanguage)
    }

    static func detect(
        in text: String,
        position: VoiceTranslationCommandPosition,
        languages: Set<String>
    ) -> VoiceTranslationCommand? {
        let words = Word.split(text)
        guard !words.isEmpty, !languages.isEmpty else { return nil }

        let trailing = longestMatch(words: words, languages: languages, trailing: true)
        let leading = position != .endOnly
            ? longestMatch(words: words, languages: languages, trailing: false)
            : nil

        // The end wins when both match; both are removed from the text.
        if let trailing {
            let leadingRange = leading.flatMap { leading in
                leading.range.upperBound <= trailing.range.lowerBound ? leading.range : nil
            }
            var remaining = text[..<trailing.range.lowerBound]
            if let leadingRange {
                remaining = dropLeadingCut(text[leadingRange.upperBound ..< trailing.range.lowerBound])
            }
            return VoiceTranslationCommand(
                targetLanguage: trailing.language,
                commandText: String(text[trailing.range]),
                remainingText: String(dropTrailingCut(remaining)),
                position: .trailing
            )
        }
        if let leading {
            return VoiceTranslationCommand(
                targetLanguage: leading.language,
                commandText: String(text[leading.range]),
                remainingText: String(dropLeadingCut(text[leading.range.upperBound...]))
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                position: .leading
            )
        }
        if position == .anywhere, let middle = middleMatch(words: words, languages: languages) {
            let before = text[..<middle.range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let after = String(dropLeadingCut(text[middle.range.upperBound...]))
            return VoiceTranslationCommand(
                targetLanguage: middle.language,
                commandText: String(text[middle.range]),
                remainingText: [before, after].filter { !$0.isEmpty }.joined(separator: " "),
                position: .middle
            )
        }
        return nil
    }

    /// Punctuation that joined the command to the dictation goes with it.
    private static func dropLeadingCut(_ text: Substring) -> Substring {
        text.drop { $0.unicodeScalars.allSatisfy(leadingCut.contains) }
    }

    private static func dropTrailingCut(_ text: Substring) -> Substring {
        var text = text
        while let last = text.last, last.unicodeScalars.allSatisfy(trailingCut.contains) {
            text.removeLast()
        }
        return text
    }

    // MARK: - Matching

    private static let maxCommandWords = 8
    private static let trailingCut = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-–—"))
    private static let leadingCut = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

    private struct Match {
        let language: String
        let range: Range<String.Index>
    }

    private static func longestMatch(words: [Word], languages: Set<String>, trailing: Bool) -> Match? {
        let count = min(maxCommandWords, words.count)
        // Longest first, so "translate it into Spanish" wins over "Spanish".
        for length in stride(from: count, through: 1, by: -1) {
            let window = trailing ? Array(words.suffix(length)) : Array(words.prefix(length))
            guard let language = language(ofCommand: window.map(\.key)), languages.contains(language),
                  let first = window.first, let last = window.last
            else { continue }
            return Match(language: language, range: first.range.lowerBound ..< last.range.upperBound)
        }
        return nil
    }

    /// The longest command strictly between the first and the last word that starts with a verb.
    private static func middleMatch(words: [Word], languages: Set<String>) -> Match? {
        guard words.count > 2 else { return nil }
        for start in 1 ..< words.count - 1 where middleVerbs.contains(words[start].key) {
            guard words[start - 1].key != "to" else { continue }
            let longest = min(maxCommandWords, words.count - 1 - start)
            for length in stride(from: longest, through: 2, by: -1) {
                let window = Array(words[start ..< start + length])
                guard let language = language(ofCommand: window.map(\.key)), languages.contains(language),
                      let last = window.last
                else { continue }
                return Match(language: language, range: words[start].range.lowerBound ..< last.range.upperBound)
            }
        }
        return nil
    }

    /// The target language when the words form a whole command, else nil.
    private static func language(ofCommand words: [String]) -> String? {
        var words = words
        while let last = words.last, closingWords.contains(last) {
            words.removeLast()
        }
        for nameLength in stride(from: min(3, words.count), through: 1, by: -1) {
            let name = words.suffix(nameLength).joined(separator: " ")
            guard let form = LanguageNames.shared.forms[name] else { continue }
            var lead = Array(words.dropLast(nameLength))
            if lead.last == "the" {
                lead.removeLast()
            }
            if isValidLead(lead, form: form) {
                return form.code
            }
        }
        return nil
    }

    private static func isValidLead(_ lead: [String], form: LanguageNames.Form) -> Bool {
        guard let preposition = lead.last else {
            // A bare language name is a command only as "українською".
            return form.kind == .instrumental
        }
        let rest = lead.dropLast()
        switch preposition {
        case "in":
            return form.kind == .name && rest.allSatisfy(englishFillers.contains)
        case "to", "into":
            return form.kind == .name && !rest.isEmpty
                && rest.allSatisfy(englishFillers.contains)
                && rest.contains(where: englishVerbs.contains)
        case "на":
            return form.kind != .instrumental && rest.allSatisfy(ukrainianFillers.contains)
        default:
            return form.kind == .instrumental && lead.allSatisfy(ukrainianFillers.contains)
        }
    }

    private static let englishVerbs = normalizedSet([
        "translate", "return", "switch", "change", "convert", "put", "make", "turn", "write"
    ])
    private static let englishFillers = englishVerbs.union(normalizedSet([
        "it", "this", "that", "all", "everything", "back", "please", "now", "text"
    ]))
    private static let middleVerbs = englishVerbs.union(normalizedSet([
        "переклади", "перекладіть", "перекласти", "переведи", "перевести",
        "поверни", "поверніть", "повернути", "зроби", "зробіть", "напиши", "напишіть"
    ]))
    private static let ukrainianFillers = normalizedSet([
        "переклади", "перекладіть", "перекласти", "переклад", "переведи", "перевести",
        "поверни", "поверніть", "повернути", "зроби", "зробіть", "напиши", "напишіть",
        "це", "все", "усе", "текст", "назад", "мені", "будь", "ласка", "тепер", "а", "і", "й"
    ])
    private static let closingWords = normalizedSet([
        "please", "language", "мовою", "мову", "мова", "будь", "ласка"
    ])

    // Words are compared after the same folding as the spoken text.
    private static func normalizedSet(_ words: [String]) -> Set<String> {
        Set(words.map(LanguageNames.normalized))
    }
}

// MARK: - Words

private struct Word {
    let key: String
    let range: Range<String.Index>

    static func split(_ text: String) -> [Word] {
        var words: [Word] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let isWordCharacter = isPart(text[index])
            if isWordCharacter, start == nil {
                start = index
            } else if !isWordCharacter, let wordStart = start {
                words.append(Word(text: text, range: wordStart ..< index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let start {
            words.append(Word(text: text, range: start ..< text.endIndex))
        }
        return words
    }

    private init(text: String, range: Range<String.Index>) {
        key = LanguageNames.normalized(String(text[range]))
        self.range = range
    }

    private static func isPart(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "'’ʼ-".contains(character)
    }
}

// MARK: - Language names

/// Spoken names of every cloud language: English, Ukrainian and its own name.
private final class LanguageNames: @unchecked Sendable {
    enum Kind {
        case name
        case instrumental
    }

    struct Form {
        let code: String
        let kind: Kind
    }

    static let shared = LanguageNames()

    let forms: [String: Form]

    private init() {
        var forms: [String: Form] = [:]
        let english = Locale(identifier: "en")
        let ukrainian = Locale(identifier: "uk")
        for language in SupportedLanguage.cloudLanguages {
            let code = language.code
            var names = [english.localizedString(forLanguageCode: code)]
            names.append(Locale(identifier: code).localizedString(forLanguageCode: code))
            for name in names.compactMap({ $0 }) {
                forms[Self.normalized(name)] = Form(code: code, kind: .name)
            }
            // "іспанська" → "іспанську" after "на", "іспанською" on its own.
            if let name = ukrainian.localizedString(forLanguageCode: code).map(Self.normalized) {
                forms[name] = Form(code: code, kind: .name)
                if name.hasSuffix("а") {
                    let stem = String(name.dropLast())
                    forms[stem + "у"] = Form(code: code, kind: .name)
                    forms[stem + "ою"] = Form(code: code, kind: .instrumental)
                }
            }
        }
        self.forms = forms
    }

    static func normalized(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "ʼ", with: "'")
    }
}
