import AppKit
import EventKit

extension AppDelegate {
    func setupCalendarIntegration() {
        let connection = CalendarConnection.shared
        connection.onReminder = { [weak self, weak connection] meetings in
            guard let self, let connection else { return }
            self.calendarReminderController.show(meetings, connection: connection)
        }
        connection.onJoin = { [weak self] meeting, record, local in
            self?.joinCalendarMeeting(meeting, record: record, local: local)
        }
        connection.onRefresh = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.calendarRecordingLinker.run(storage: .shared, connection: .shared) }
        }
        connection.start()
        _ = BrowserCalendarConnection.shared
        calendarStoreObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in await CalendarConnection.shared.refresh() }
        }
        calendarWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                CalendarConnection.shared.resetReminderSession()
                await CalendarConnection.shared.refresh()
            }
        }
        // Reminders wait while the screen is locked; a meeting still running is offered after unlock.
        calendarLockObservers = [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)].map { name, locked in
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                Task { @MainActor in CalendarConnection.shared.setScreenLocked(locked) }
            }
        }
    }

    /// Opens a validated meeting link the way Calendar settings ask: Zoom/Teams app, chosen browser or default browser.
    static func openMeetingLink(_ url: URL, configuration: CalendarConfiguration = CalendarConnection.shared.configuration) -> Bool {
        switch CalendarMeeting.openTarget(for: url, configuration: configuration,
                                          appInstalled: { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil }) {
        case let .app(appLink):
            return NSWorkspace.shared.open(appLink)
        case let .browser(link, bundleID):
            guard let bundleID, let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return NSWorkspace.shared.open(link)
            }
            NSWorkspace.shared.open([link], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(link) } }
            }
            return true
        }
    }

    func joinCalendarMeeting(_ meeting: CalendarMeeting, record: Bool, local: Bool,
                             openURL: (URL) -> Bool = { AppDelegate.openMeetingLink($0) }) {
        let opened: Bool
        if let url = meeting.meetingURL {
            guard CalendarMeeting.isJoinURL(url) else { return }
            opened = openURL(url)
        } else {
            guard record else { return }
            opened = true
        }
        let alreadyRecording = appState.meetingRecordingState == .recording
        let busy = appState.meetingRecordingState == .processing ||
            appState.recordingState == .recording || appState.recordingState == .processing ||
            appState.translationRecordingState == .recording || appState.translationRecordingState == .processing ||
            appState.meetingTranslationRecordingState == .recording || appState.meetingTranslationRecordingState == .processing
        switch CalendarJoinDecision.resolve(record: record, openingSucceeded: opened, alreadyRecording: alreadyRecording, busy: busy, isSignedIn: AuthService.shared.isLoggedIn, hasMeetingURL: meeting.meetingURL != nil) {
        case .joinOnly: break
        case let .signInRequired(showAccount):
            if showAccount {
                openSettings(tab: .account)
            } else {
                DictationOverlayController.shared.showInfo(message: String(localized: "The meeting is open. Sign in to Diduny in Account settings before starting a recording."), duration: 5)
            }
        case .openFailed:
            DictationOverlayController.shared.showInfo(message: String(localized: "The meeting link could not be opened. Recording has not started."))
        case .recordingUnavailable:
            DictationOverlayController.shared.showInfo(message: String(localized: "The meeting is open. Finish the current recording task before starting another."))
        case let .linkExisting(showLibrary):
            if let id = meetingRecorderService.currentRecordingId,
               RecordingsLibraryStorage.shared.linkCalendarMeeting(id: id, meeting: meeting) {
                if showLibrary { openMainWindow(section: .recordings) }
            } else {
                DictationOverlayController.shared.showInfo(message: String(localized: "The current recording could not be linked. An existing meeting link was kept."))
            }
        case let .startRecording(showLibrary):
            toggleMeetingRecording(provider: local ? .local : .cloud, calendarMeeting: meeting)
            if showLibrary { openMainWindow(section: .recordings) }
        }
    }
}

/// Links meeting recordings, including ones made before the calendar was connected, to the
/// calendar events they overlap. Runs after calendar reads, but only when the set of unlinked
/// recordings or selected calendars changed.
@MainActor final class CalendarRecordingLinker {
    private var signature = ""
    private var running = false

    func run(storage: RecordingsLibraryStorage, connection: CalendarConnection) async {
        guard !running, connection.configuration.connected, !connection.configuration.selected.isEmpty else { return }
        let pending = Self.pending(in: storage)
        guard !pending.isEmpty, Self.signature(pending, connection) != signature,
              let from = pending.map({ $0.start }).min(), let to = pending.map({ $0.end }).max() else { return }
        running = true
        defer { running = false }
        guard let events = try? await connection.readMeetings(from: from.addingTimeInterval(-86400), to: to.addingTimeInterval(86400)) else { return }
        var matches: [UUID: CalendarRecordingMatch] = [:]
        for recording in pending {
            matches[recording.id] = CalendarMeeting.match(recordingStart: recording.start, recordingEnd: recording.end, events: events)
        }
        // Remember what is still unlinked after saving, so unchanged leftovers are not read again.
        if storage.applyCalendarMatches(matches) { signature = Self.signature(Self.pending(in: storage), connection) }
    }

    private static func pending(in storage: RecordingsLibraryStorage) -> [(id: UUID, start: Date, end: Date)] {
        storage.recordings.compactMap { recording in
            guard recording.type.isMeetingLike, recording.calendarMeeting == nil, recording.calendarLinkDeclined != true,
                  !recording.status.isInProgressCapture, let end = recording.resolvedEndedAt, end > recording.createdAt
            else { return nil }
            return (recording.id, recording.createdAt, end)
        }
    }

    private static func signature(_ pending: [(id: UUID, start: Date, end: Date)], _ connection: CalendarConnection) -> String {
        connection.configuration.selected.sorted().joined(separator: ",") + "|"
            + pending.map { $0.id.uuidString }.sorted().joined(separator: ",")
    }
}
