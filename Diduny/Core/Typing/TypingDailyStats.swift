import Foundation
import Observation

/// Layout fixes per day for Overview: counts only, never the fixed text. `typing_stats_daily.json`
/// next to `usage_stats_archive.json`. Seconds are computed when read, with the current typing speed.
struct TypingDayStat: Codable, Equatable {
    var day: String
    var fixCount: Int
    var wordCount: Int

    /// Papuga's aggregate formula: 2 s to notice and fix, plus typing the fixed words again.
    static func secondsSaved(_ rows: some Sequence<TypingDayStat>, wordsPerMinute: Double) -> Double {
        let fixes = rows.reduce(0) { $0 + $1.fixCount }
        let words = rows.reduce(0) { $0 + $1.wordCount }
        return Double(fixes) * 2.0 + Double(words) * 60 / max(wordsPerMinute, 1)
    }

    /// Papuga counts space-separated parts, at least 1.
    static func wordCount(of text: String) -> Int {
        max(1, text.split(whereSeparator: \.isWhitespace).count)
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Local midnight of `day`.
    func date(calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

@MainActor
@Observable
final class TypingDailyStatsStore {
    static let shared = TypingDailyStatsStore()

    private(set) var rows: [TypingDayStat] = []
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let now: () -> Date

    init(directory: URL = RecordingsLibraryStorage.defaultAppDirectory, now: @escaping () -> Date = Date.init) {
        url = directory.appendingPathComponent("typing_stats_daily.json")
        self.now = now
        if let data = try? Data(contentsOf: url), let loaded = try? JSONDecoder().decode([TypingDayStat].self, from: data) {
            rows = loaded
        }
    }

    func recordFix(text: String) { bump(fixes: 1, words: TypingDayStat.wordCount(of: text)) }

    /// An undone fix takes back what it added, never below 0.
    func reverseFix(text: String) { bump(fixes: -1, words: -TypingDayStat.wordCount(of: text)) }

    /// Rows whose local midnight is in `from ..< to`.
    func rows(from: Date, to: Date = .distantFuture) -> [TypingDayStat] {
        rows.filter { row in row.date().map { $0 >= from && $0 < to } ?? false }
    }

    private func bump(fixes: Int, words: Int) {
        let key = TypingDayStat.dayKey(now())
        if let index = rows.firstIndex(where: { $0.day == key }) {
            rows[index].fixCount = max(0, rows[index].fixCount + fixes)
            rows[index].wordCount = max(0, rows[index].wordCount + words)
        } else if fixes > 0 {
            rows.append(TypingDayStat(day: key, fixCount: fixes, wordCount: max(0, words)))
        } else {
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(rows).write(to: url, options: .atomic)
    }
}
