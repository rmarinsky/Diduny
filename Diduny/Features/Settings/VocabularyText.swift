import SwiftUI

/// The lines under a word and under a waiting item on "Vocabulary & context" (spec 03, 1.1 and 1.2).
enum VocabularyText {
    static func sourceLine(_ meta: VocabularyWordMeta) -> LocalizedStringKey {
        guard meta.source == .addedAutomatically, let evidence = meta.evidence else { return "From typing" }
        let date = shortDate(meta.addedAt)
        switch evidence.signal {
        case .undo:
            return "Added automatically, \(date). Layout fix undone \(evidence.count) times"
        case .typed, .manualSwitch:
            return "Added automatically, \(date). Typed \(evidence.count) times on \(evidence.days) days"
        }
    }

    static func reasonLine(_ item: VocabularyPendingItem) -> LocalizedStringKey {
        let count = item.evidence.count
        switch item.evidence.signal {
        case .undo: return "You undid its layout fix \(count) times."
        case .typed: return "Typed \(count) times on \(item.evidence.days) days."
        case .manualSwitch:
            return "You switched it by hand \(count) times. Replacements change your text, so they are never added without you."
        }
    }

    /// Day and short month; the year only when it is not this year.
    static func shortDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

extension VocabularyPendingItem {
    var isWord: Bool {
        if case .word = kind { return true }
        return false
    }

    /// The word, or the source of a replacement: names the row for VoiceOver.
    var title: String {
        switch kind {
        case let .word(word): word
        case let .replacement(from, _): from
        }
    }
}
