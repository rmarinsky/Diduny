import Foundation

/// Soniox v6 returns spoken punctuation and edit commands as words ("period", «новий рядок», "usuń to");
/// this applies them to final Diduny Cloud dictation text (uk, en, pl). Not for meetings or translations.
enum SpokenCommandProcessor {
    private enum Command {
        case punctuation(String)
        case lineBreak(String)
        case deleteSentence
    }

    private static let commands: [(phrases: [String], command: Command)] = [
        (["крапка з комою"], .punctuation(";")),
        (["кома", "comma", "przecinek"], .punctuation(",")),
        (["крапка", "period", "full stop", "kropka"], .punctuation(".")),
        (["знак питання", "question mark", "znak zapytania"], .punctuation("?")),
        (["знак оклику", "exclamation mark", "exclamation point", "wykrzyknik"], .punctuation("!")),
        (["двокрапка", "colon", "dwukropek"], .punctuation(":")),
        (["новий рядок", "new line", "nowa linia"], .lineBreak("\n")),
        (["новий абзац", "new paragraph", "nowy akapit"], .lineBreak("\n\n")),
        (["скасуй це", "видали це", "scratch that", "usuń to"], .deleteSentence)
    ]

    private static let lookup: [String: Command] = Dictionary(
        commands.flatMap { entry in entry.phrases.map { ($0, entry.command) } }, uniquingKeysWith: { first, _ in first }
    )

    /// Whole words only, longest phrase first («крапка з комою» before «крапка»); punctuation the model attached
    /// right after the command is part of the match.
    private static let regex: NSRegularExpression = {
        let alternatives = lookup.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
        let pattern = #"(?<![\p{L}\p{N}])("# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}])[,.;:!?…]*"#
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// A command word after one of these is an ordinary noun ("the period of time", «ця крапка»), so it stays text.
    private static let determiners: Set<String> = [
        "the", "a", "an", "this", "that", "each", "every", "my", "your", "our", "one",
        "ця", "кожна", "одна", "цей", "той", "кожен", "один", "мій", "моя",
        "ta", "ten", "każda", "każdy", "jedna", "jeden", "moja", "mój"
    ]

    /// Looks only at the word right before `location`, scanning back from it.
    private static func followsDeterminer(_ location: Int, in text: NSString) -> Bool {
        let letters = CharacterSet.letters
        func isLetter(_ index: Int) -> Bool {
            guard let scalar = UnicodeScalar(text.character(at: index)) else { return true } // surrogate half
            return letters.contains(scalar)
        }
        var end = location
        while end > 0, !isLetter(end - 1) { end -= 1 }
        var start = end
        while start > 0, isLetter(start - 1) { start -= 1 }
        guard start < end else { return false }
        return determiners.contains(text.substring(with: NSRange(location: start, length: end - start)).lowercased())
    }

    private static let attachedPunctuation = Set(",.;:!?…")

    /// The last . ? ! or newline that ends a sentence; a period between digits (3.14) is not one.
    private static func lastSentenceBoundary(in text: String) -> String.Index? {
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            let char = text[index]
            guard sentenceEnds.contains(char) || char == "\n" else { continue }
            if char == ".", index > text.startIndex, text[text.index(before: index)].isNumber,
               text.index(after: index) < text.endIndex, text[text.index(after: index)].isNumber { continue }
            return index
        }
        return nil
    }
    private static let sentenceEnds = Set(".?!")

    static func apply(_ text: String) -> String {
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var output = ""
        var separator = ""
        var capitalize = false
        var position = 0
        for match in matches where !followsDeterminer(match.range.location, in: nsText) {
            append(nsText.substring(with: NSRange(location: position, length: match.range.location - position)),
                   to: &output, separator: &separator, capitalize: &capitalize, first: position == 0)
            position = match.range.location + match.range.length
            let phrase = nsText.substring(with: match.range(at: 1)).lowercased()
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard let command = lookup[phrase] else { continue }

            switch command {
            case let .punctuation(mark):
                trimEnd(&output) { $0 == " " || $0 == "\t" || attachedPunctuation.contains($0) }
                guard let last = output.last, last != "\n" else { continue }
                output += mark
                separator = " "
                capitalize = sentenceEnds.contains(Character(mark))
            case let .lineBreak(breaks):
                trimEnd(&output) { $0 == " " || $0 == "\t" || $0 == "," }
                output += breaks
                separator = ""
                capitalize = true
            case .deleteSentence:
                trimEnd(&output) { $0.isWhitespace || $0 == "," || $0 == ";" || $0 == ":" }
                trimEnd(&output) { sentenceEnds.contains($0) }
                if let end = lastSentenceBoundary(in: output) {
                    output = String(output[...end])
                } else {
                    output = ""
                }
                separator = output.isEmpty || output.last == "\n" ? "" : " "
                capitalize = true
            }
        }
        append(nsText.substring(from: position), to: &output, separator: &separator, capitalize: &capitalize,
               first: position == 0)
        return output
    }

    /// Text between commands: after a command it starts with one separator and, after a sentence end, a capital.
    private static func append(_ segment: String, to output: inout String, separator: inout String,
                               capitalize: inout Bool, first: Bool) {
        guard !first else {
            output += segment
            return
        }
        let trimmed = segment.drop { $0.isWhitespace }
        guard let head = trimmed.first else { return }
        output += separator + (capitalize ? head.uppercased() : String(head)) + trimmed.dropFirst()
        separator = ""
        capitalize = false
    }

    private static func trimEnd(_ text: inout String, while predicate: (Character) -> Bool) {
        while let last = text.last, predicate(last) {
            text.removeLast()
        }
    }
}
