@testable import Diduny
import XCTest

/// History retention removes recordings, but their numbers must stay in Overview.
@MainActor
final class UsageStatsArchiveTests: XCTestCase {
    private var originalDictationRetention: HistoryRetentionPolicy!
    private var directory: URL!

    override func setUp() async throws {
        originalDictationRetention = SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy
        SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy = .days7
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy = originalDictationRetention
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() throws -> RecordingsLibraryStorage {
        try RecordingsLibraryStorage(baseDirectory: directory, batchStorage: TranscriptionBatchStorage(baseDirectory: directory))
    }

    func test_pruningKeepsStatsAndReloadsThemAfterRestart() throws {
        let store = try makeStore()
        XCTAssertNotNil(store.saveRecording(audioData: Data([1]), type: .voice, duration: 6,
                                            transcriptionText: "one two three four", forceSave: true))
        let before = RecordingStatistics(rows: store.usageStatRows)

        store.pruneExpiredRecordings(now: Date().addingTimeInterval(30 * 86400))
        XCTAssertTrue(store.recordings.isEmpty)
        let after = RecordingStatistics(rows: store.usageStatRows)
        XCTAssertEqual(after.recordingCount, 1)
        XCTAssertEqual(after.transcribedWordCount, before.transcribedWordCount)
        XCTAssertEqual(after.totalDurationSeconds, before.totalDurationSeconds)

        let reloaded = RecordingStatistics(rows: try makeStore().usageStatRows)
        XCTAssertEqual(reloaded.recordingCount, 1)
        XCTAssertEqual(reloaded.transcribedWordCount, 4)
    }

    func test_pruningAgainDoesNotDoubleCount() throws {
        let store = try makeStore()
        XCTAssertNotNil(store.saveRecording(audioData: Data([1]), type: .voice, duration: 2,
                                            transcriptionText: "hi", forceSave: true))
        let later = Date().addingTimeInterval(30 * 86400)
        store.pruneExpiredRecordings(now: later)
        store.pruneExpiredRecordings(now: later)
        XCTAssertEqual(store.usageStatRows.count, 1)
    }

    func test_manualDeleteRemovesTheRecordingFromStats() throws {
        let store = try makeStore()
        let id = try XCTUnwrap(store.saveRecording(audioData: Data([1]), type: .voice, duration: 2,
                                                   transcriptionText: "hi", forceSave: true))
        XCTAssertTrue(store.deleteRecordings([id]))
        XCTAssertTrue(store.usageStatRows.isEmpty)
    }

    func test_neverRetentionSavesNoRecordingButCountsItsStats() throws {
        SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy = .never
        let store = try makeStore()
        XCTAssertNil(store.saveRecording(audioData: Data([1]), type: .voice, duration: 3,
                                         transcriptionText: "five words are said here"))
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertEqual(RecordingStatistics(rows: store.usageStatRows).transcribedWordCount, 5)
        XCTAssertEqual(RecordingStatistics(rows: try makeStore().usageStatRows).recordingCount, 1)
    }
}
