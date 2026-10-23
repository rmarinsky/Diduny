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

    func joinCalendarMeeting(_ meeting: CalendarMeeting, record: Bool, local: Bool,
                             openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
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
