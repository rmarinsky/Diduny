import Foundation
import Testing
@testable import Diduny

@MainActor
struct MeetingsSettingsTests {
    // MARK: Level from a buffer

    @Test func silenceIsZeroAndFullScaleIsOne() {
        #expect(AudioLevel.of([]) == 0)
        #expect(AudioLevel.of([Float](repeating: 0, count: 512)) == 0)
        #expect(AudioLevel.of([Float](repeating: 1, count: 512)) == 1)
    }

    @Test func levelFollowsDecibelsOverSixtyRange() {
        // 0.1 amplitude is -20 dB, so (-20 + 60) / 60.
        let level = AudioLevel.of([Float](repeating: 0.1, count: 512))
        #expect(abs(level - 40.0 / 60.0) < 0.001)
        #expect(AudioLevel.of([Float](repeating: 0.2, count: 512)) > level)
    }

    // MARK: Browser switch

    @Test func defaultIsOnOnlyWithASavedBrowser() {
        #expect(BrowserCalendarSetting.resolve(stored: nil, hasSavedConnection: true))
        #expect(!BrowserCalendarSetting.resolve(stored: nil, hasSavedConnection: false))
    }

    @Test func aStoredChoiceWinsOverTheDefault() {
        #expect(!BrowserCalendarSetting.resolve(stored: false, hasSavedConnection: true))
        #expect(BrowserCalendarSetting.resolve(stored: true, hasSavedConnection: false))
    }

    private func makeConnection(saved: SavedConnection?, stored: Bool?) throws -> (BrowserCalendarConnection, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        if let saved { try ConnectionStore(directory: dir).save(saved) }
        let defaults = try #require(UserDefaults(suiteName: "MeetingsSettingsTests.\(UUID().uuidString)"))
        let settings = SettingsStorage(defaults: defaults)
        if let stored { settings.setBrowserCalendarEnabled(stored) }
        return (BrowserCalendarConnection(directory: dir, settings: settings), dir)
    }

    private let saved = SavedConnection(
        browserID: "com.google.Chrome", profileName: "Work",
        calendarURL: URL(string: "https://calendar.google.com/calendar/u/0/r")!)

    @Test func withTheSwitchOffNoBrowserReadHappens() throws {
        let (connection, dir) = try makeConnection(saved: saved, stored: false)
        defer { connection.stop(); try? FileManager.default.removeItem(at: dir) }
        #expect(!connection.enabled)
        connection.read(force: true)
        #expect(!connection.busy)
        #expect(connection.lastAttempt == nil)
        connection.openCalendar(
            browser: InstalledBrowser(id: "com.google.Chrome", name: "Chrome", url: URL(fileURLWithPath: "/Applications/Google Chrome.app"), profiles: []),
            profileID: "x", url: saved.calendarURL)
        #expect(!connection.busy)
    }

    @Test func turningTheSwitchOffKeepsTheChosenBrowser() throws {
        let (connection, dir) = try makeConnection(saved: saved, stored: true)
        defer { connection.stop(); try? FileManager.default.removeItem(at: dir) }
        #expect(connection.enabled)
        connection.setEnabled(false)
        #expect(!connection.enabled)
        #expect(!connection.busy)
        #expect(connection.result == nil)
        #expect(connection.saved == saved)
        #expect(try ConnectionStore(directory: dir).load() == saved)
    }
}
