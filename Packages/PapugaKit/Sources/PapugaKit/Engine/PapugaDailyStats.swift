import Foundation

/// Per-day replacement totals. Persisted by the host app as a flat array keyed
/// by the calendar day (`yyyy-MM-dd`) so the analytics tab can render a
/// 30-day chart and Day / Week / Month / All scopes the way BrowserCat does.
struct PapugaDailyStats: Codable, Equatable, Identifiable {
    let day: String
    var replacementCount: Int
    var wordsCount: Int
    var secondsSaved: Int

    var id: String { day }

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(for date: Date = Date()) -> String {
        isoFormatter.string(from: date)
    }

    var date: Date? {
        Self.isoFormatter.date(from: day)
    }
}

enum PapugaStatsAggregator {
    /// Aggregates raw replacement-log entries into per-day totals, netting out
    /// undone auto-fixes exactly as the live counters do (`reverseReplacement`
    /// subtracts the same word count that the apply added). Word counts come from
    /// the stored `converted` text; entries truncated at 80 chars slightly
    /// undercount, which keeps the recovered number conservative.
    /// `measuredTypingWPM` was the Papuga setting `measuredTypingWPM` (default 0 = not measured).
    static func dailyStats(from entries: [ReplacementHistoryEntry], measuredTypingWPM: Double = 0) -> [PapugaDailyStats] {
        var byDay: [String: PapugaDailyStats] = [:]
        for entry in entries {
            let sign = entry.kind == .autoFixUndone ? -1 : 1
            let words = max(1, entry.converted.split(separator: " ").count)
            let seconds = Constants.secondsSaved(words: words, measuredTypingWPM: measuredTypingWPM)
            let day = PapugaDailyStats.dayString(for: entry.timestamp)
            var stat = byDay[day] ?? PapugaDailyStats(day: day, replacementCount: 0, wordsCount: 0, secondsSaved: 0)
            stat.replacementCount += sign
            stat.wordsCount += sign * words
            stat.secondsSaved += sign * seconds
            byDay[day] = stat
        }
        return byDay.values
            .filter { $0.replacementCount > 0 }
            .map { PapugaDailyStats(
                day: $0.day,
                replacementCount: max(0, $0.replacementCount),
                wordsCount: max(0, $0.wordsCount),
                secondsSaved: max(0, $0.secondsSaved)
            ) }
            .sorted { $0.day < $1.day }
    }
}
