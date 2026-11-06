import Foundation

/// One turn of the live meeting translation (01 section 3 item 4, N9, N10): who spoke, in which
/// language, the original words and the translation into the other language of the pair.
struct TranslateMeetingTurn: Equatable, Identifiable {
    let id: Int
    var speaker: String?
    /// Spoken language code, from the original tokens (or a translated token's source language).
    var spokenLanguage: String?
    /// Shown language code, from the translated tokens; else the other language of the pair.
    var shownLanguage: String?
    var original = ""
    var translation = ""

    /// "Speaker 1 · UK → EN"; without a speaker "UK → EN"; without languages "Speaker 1"; nil with neither.
    var label: String? {
        let direction: String? = if let spokenLanguage, let shownLanguage {
            "\(spokenLanguage.uppercased()) → \(shownLanguage.uppercased())"
        } else {
            nil
        }
        let speakerText = speaker.map { String(localized: "Speaker \($0)") }
        switch (speakerText, direction) {
        case let (speakerText?, direction?): return "\(speakerText) · \(direction)"
        case let (speakerText?, nil): return speakerText
        case let (nil, direction?): return direction
        case (nil, nil): return nil
        }
    }
}

/// Builds turns from the two-way Soniox stream, originals included. Originals and translations are
/// not 1-to-1 and translated tokens carry no timestamps, so pairing follows token order
/// (translation-support.md section 4): an original after translated text opens a new turn.
/// Translated tokens without a speaker keep the turn's speaker. Pure: the panel owns the instance.
struct TranslateMeetingTranscript: Equatable {
    /// Same statuses the meeting translation filter treats as translated (`AppDelegate+MeetingTranslationRecording`).
    static let translatedStatuses: Set<String> = [
        "translation", "translated", "translated_text", "translation_text", "target", "output",
    ]

    private(set) var committed: [TranslateMeetingTurn] = []
    /// Non-final tokens of the latest batch, laid on top of `committed`; replaced by every batch.
    private(set) var provisional: [TranslateMeetingTurn] = []
    private var pair: TranslationLanguagePair

    init(pair: TranslationLanguagePair) {
        self.pair = pair
    }

    var turns: [TranslateMeetingTurn] {
        guard let first = provisional.first else { return committed }
        guard var last = committed.last, Self.continues(last, with: first) else { return committed + provisional }
        last.original += first.original
        last.translation += first.translation
        last.spokenLanguage = last.spokenLanguage ?? first.spokenLanguage
        last.shownLanguage = last.shownLanguage ?? first.shownLanguage
        return committed.dropLast() + [last] + provisional.dropFirst()
    }

    /// Translations only, one turn per paragraph, with its label: the text Copy takes.
    var translationText: String {
        turns.filter { !$0.translation.isEmpty }.map { turn in
            let text = turn.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            return turn.label.map { "\($0)\n\(text)" } ?? text
        }.joined(separator: "\n\n")
    }

    mutating func reset(pair: TranslationLanguagePair) {
        self = TranslateMeetingTranscript(pair: pair)
    }

    mutating func process(_ tokens: [RealtimeToken]) {
        var nextProvisional: [TranslateMeetingTurn] = []
        var sawProvisional = false
        for token in tokens where !token.text.isEmpty {
            if token.isFinal {
                append(token, to: &committed, idBase: 0)
            } else {
                sawProvisional = true
                append(token, to: &nextProvisional, idBase: 1_000_000)
            }
        }
        if sawProvisional {
            provisional = nextProvisional
        } else if tokens.contains(where: \.isFinal) {
            provisional = []
        }
    }

    private func append(_ token: RealtimeToken, to turns: inout [TranslateMeetingTurn], idBase: Int) {
        let isTranslation = Self.isTranslated(token)
        let language = Self.code(token.language)
        let speaker = token.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        let startsNewTurn: Bool = if let last = turns.last {
            (speaker != nil && last.speaker != nil && speaker != last.speaker)
                || (!isTranslation && !last.translation.isEmpty)
        } else {
            true
        }
        if startsNewTurn {
            turns.append(TranslateMeetingTurn(id: idBase + committed.count + turns.count, speaker: speaker))
        }

        var turn = turns[turns.count - 1]
        if turn.speaker == nil { turn.speaker = speaker }
        if isTranslation {
            turn.translation += token.text
            turn.shownLanguage = turn.shownLanguage ?? language
            turn.spokenLanguage = turn.spokenLanguage ?? Self.code(token.sourceLanguage)
        } else {
            turn.original += token.text
            turn.spokenLanguage = turn.spokenLanguage ?? language
        }
        if turn.shownLanguage == nil, let spoken = turn.spokenLanguage, pair.contains(spoken) {
            turn.shownLanguage = pair.opposite(of: spoken)
        }
        turns[turns.count - 1] = turn
    }

    private static func continues(_ last: TranslateMeetingTurn, with next: TranslateMeetingTurn) -> Bool {
        if let a = last.speaker, let b = next.speaker, a != b { return false }
        return next.original.isEmpty || last.translation.isEmpty
    }

    static func isTranslated(_ token: RealtimeToken) -> Bool {
        guard let status = token.translationStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return false }
        return translatedStatuses.contains(status)
    }

    private static func code(_ raw: String?) -> String? {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
