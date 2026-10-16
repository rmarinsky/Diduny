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
            Task { @MainActor in await CalendarConnection.shared.refresh() }
        }
    }

    func joinCalendarMeeting(_ meeting: CalendarMeeting, record: Bool, local: Bool) {
        let opened: Bool
        if let url = meeting.meetingURL {
            guard CalendarMeeting.isJoinURL(url) else { return }
            opened = NSWorkspace.shared.open(url)
        } else {
            guard record else { return }
            opened = true
        }
        let alreadyRecording = appState.meetingRecordingState == .recording
        let busy = appState.meetingRecordingState == .processing ||
            appState.recordingState == .recording || appState.recordingState == .processing ||
            appState.translationRecordingState == .recording || appState.translationRecordingState == .processing ||
            appState.meetingTranslationRecordingState == .recording || appState.meetingTranslationRecordingState == .processing
        switch CalendarJoinDecision.resolve(record: record, openingSucceeded: opened, alreadyRecording: alreadyRecording, busy: busy, isSignedIn: AuthService.shared.isLoggedIn) {
        case .joinOnly: break
        case .signInRequired:
            openSettings(tab: .account)
        case .openFailed:
            DictationOverlayController.shared.showInfo(message: String(localized: "The meeting link could not be opened. Recording has not started."))
        case .recordingUnavailable:
            DictationOverlayController.shared.showInfo(message: String(localized: "The meeting is open. Finish the current recording task before starting another."))
        case .linkExisting:
            if let id = meetingRecorderService.currentRecordingId,
               RecordingsLibraryStorage.shared.linkCalendarMeeting(id: id, meeting: meeting) {
                openMainWindow(section: .recordings)
            } else {
                DictationOverlayController.shared.showInfo(message: String(localized: "The current recording could not be linked. An existing meeting link was kept."))
            }
        case .startRecording:
            toggleMeetingRecording(provider: local ? .local : .cloud, calendarMeeting: meeting)
            openMainWindow(section: .recordings)
        }
    }
}
