@testable import Diduny
import Foundation
import Testing

/// Spec 05: layout fixes per day for Overview, and the update state shown on three places.
@MainActor
struct OverviewTypingAndUpdateTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    @Test func secondsUsePapugaFormulaWithCurrentSpeed() {
        let rows = [TypingDayStat(day: "2026-11-12", fixCount: 3, wordCount: 4), TypingDayStat(day: "2026-11-13", fixCount: 1, wordCount: 2)]
        // 4 fixes x 2 s + 6 words x 60 / 40 WPM = 8 + 9
        #expect(TypingDayStat.secondsSaved(rows, wordsPerMinute: 40) == 17)
        #expect(TypingDayStat.secondsSaved(rows, wordsPerMinute: 60) == 14)
    }

    @Test func wordCountIsAtLeastOne() {
        #expect(TypingDayStat.wordCount(of: "привіт") == 1)
        #expect(TypingDayStat.wordCount(of: "hello  world") == 2)
        #expect(TypingDayStat.wordCount(of: "") == 1)
    }

    @Test func storeKeepsCountsOnlyAndUndoNeverGoesBelowZero() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TypingDailyStatsStore(directory: directory, now: { day })
        store.recordFix(text: "secret words")
        store.recordFix(text: "x")
        store.reverseFix(text: "secret words")
        store.reverseFix(text: "secret words")
        #expect(store.rows == [TypingDayStat(day: TypingDayStat.dayKey(day), fixCount: 0, wordCount: 0)])

        store.recordFix(text: "secret words")
        let file = try String(contentsOf: directory.appendingPathComponent("typing_stats_daily.json"), encoding: .utf8)
        #expect(!file.contains("secret"))
        #expect(TypingDailyStatsStore(directory: directory).rows == store.rows)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func undoWithNoFixTodayAddsNothing() {
        let store = TypingDailyStatsStore(directory: directory)
        store.reverseFix(text: "a")
        #expect(store.rows.isEmpty)
    }

    @Test func rowsCountForAPeriodByLocalMidnight() {
        let store = TypingDailyStatsStore(directory: directory, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        store.recordFix(text: "a")
        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(store.rows(from: midnight).count == 1)
        #expect(store.rows(from: midnight.addingTimeInterval(1)).isEmpty)
        #expect(store.rows(from: .distantPast, to: midnight).isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func updateStateTexts() {
        let status = UpdateStatus()
        #expect(status.cardTitle == nil && status.panelText == nil && status.aboutHeadline == nil)
        #expect(!status.canRestart)

        status.phase = .downloading(version: "1.15.0")
        #expect(status.cardTitle == "Downloading Diduny 1.15.0")
        #expect(!status.showsRestartButton)

        status.phase = .waiting(version: "1.15.0")
        #expect(status.cardTitle == "Diduny 1.15.0 is ready")
        #expect(status.cardDetail == "Downloaded in the background. Restarting takes a few seconds.")
        #expect(status.aboutButtonTitle == "Restart to update")
        #expect(status.canRestart)

        status.isBusy = true
        #expect(status.cardDetail == "Finish the recording first.")
        #expect(!status.canRestart)

        status.phase = .restarting
        #expect(status.cardDetail == nil && !status.showsRestartButton && !status.canRestart)
    }

    @Test func restartCallsInstallOnlyWhenAllowed() {
        let status = UpdateStatus()
        var calls = 0
        status.restartNow = { calls += 1 }
        status.restart()
        status.phase = .waiting(version: "2.23.0")
        status.isBusy = true
        status.restart()
        #expect(calls == 0)
        status.isBusy = false
        status.restart()
        #expect(calls == 1)
    }
}
