import AppIntents
import AppKit
import EventKit

extension AppDelegate {
    func setupCalendarIntegration() {
        let connection = CalendarConnection.shared
        connection.onReminder = { [weak self, weak connection] meetings in
            guard let self, let connection else { return }
            self.calendarReminderController.show(meetings, connection: connection)
        }
        connection.onEarlyReminder = { [weak self, weak connection] meetings in
            guard let self, let connection else { return }
            self.calendarReminderController.showEarly(meetings, connection: connection)
        }
        connection.onJoin = { [weak self] meeting, record, local in
            self?.joinCalendarMeeting(meeting, record: record, local: local)
        }
        connection.onRefresh = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.calendarRecordingLinker.run(storage: .shared, connection: .shared) }
        }
        connection.onTick = { [weak self] in self?.offerStopIfLinkedMeetingEnded() }
        connection.start()
        _ = BrowserCalendarConnection.shared
        calendarStoreObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.calendarRecordingLinker.calendarChanged()
                await CalendarConnection.shared.refresh()
            }
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

    /// The calendar meeting being recorded has ended: offer to stop instead of recording on silently.
    func offerStopIfLinkedMeetingEnded(now: Date = Date()) {
        guard appState.meetingRecordingState == .recording else { return }
        let recordingID = meetingRecorderService.currentRecordingId
        let stored = recordingID.flatMap { id in RecordingsLibraryStorage.shared.recordings.first(where: { $0.id == id })?.calendarMeeting }
        // A meeting extended or moved in Calendar after linking ends when Calendar now says.
        let linked = stored.map { stored in CalendarConnection.shared.meetings.first(where: { $0.id == stored.id }) ?? stored }
        guard CalendarMeeting.stopPromptDue(meeting: linked, recordingID: recordingID, offered: meetingEndPromptsOffered, now: now,
                                            callActive: meetingJoinMonitor.isCallActive),
              let id = recordingID, let meeting = linked else { return }
        meetingEndPromptsOffered.insert(id)
        let title = CalendarConnection.shared.configuration.hideNames ? String(localized: "Meeting") : meeting.title
        calendarReminderController.showMeetingEnded(title: String(localized: "\(title) has ended"),
                                                    message: String(localized: "Diduny is still recording this meeting.")) { [weak self] in
            self?.stopMeetingRecording(ifCurrent: id)
        }
    }

    /// The call detector saw the call end while a meeting is recorded. Rejoining closes the offer.
    func offerStopAfterCallEnded(_ call: DetectedMeeting) {
        guard appState.meetingRecordingState == .recording, let id = meetingRecorderService.currentRecordingId else { return }
        meetingEndPromptsOffered.insert(id) // The calendar end prompt is not needed after this one.
        calendarReminderController.showMeetingEnded(
            title: String(localized: "Looks like the call ended"),
            message: String(localized: "\(call.client.displayName) stopped. Diduny is still recording. If you rejoin, recording just continues.")
        ) { [weak self] in
            self?.stopMeetingRecording(ifCurrent: id)
        }
    }

    /// Back in a call: the stop offer closes and recording continues.
    func closeStopOfferAfterRejoin() {
        guard calendarReminderController.isShowingMeetingEnded else { return }
        calendarReminderController.closeMeetingEnded()
        if appState.meetingRecordingState == .recording {
            DictationOverlayController.shared.showInfoDuringRecording(
                message: String(localized: "Back in the call — still recording"), mode: .meeting, duration: 3)
        }
    }

    private func stopMeetingRecording(ifCurrent id: UUID) {
        guard appState.meetingRecordingState == .recording, meetingRecorderService.currentRecordingId == id else { return }
        toggleMeetingRecording()
    }

    /// Opens a validated meeting link the way Calendar settings ask: Zoom/Teams app, chosen browser or default browser.
    static func openMeetingLink(_ url: URL, configuration: CalendarConfiguration) -> Bool {
        switch CalendarMeeting.openTarget(for: url, configuration: configuration,
                                          appInstalled: { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil }) {
        case let .app(appLink):
            return NSWorkspace.shared.open(appLink) || NSWorkspace.shared.open(url)
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
                             openURL: ((URL) -> Bool)? = nil) {
        let openURL = openURL ?? { AppDelegate.openMeetingLink($0, configuration: CalendarConnection.shared.configuration) }
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
/// calendar events they overlap. Runs after calendar reads; each recording is tried once per
/// calendar selection, reading only the time around it.
@MainActor final class CalendarRecordingLinker {
    private var attempted = Set<UUID>()
    private var selection = ""
    private var running = false

    func run(storage: RecordingsLibraryStorage, connection: CalendarConnection) async {
        guard !running, connection.configuration.connected, connection.configuration.eventDetails,
              !connection.configuration.selected.isEmpty else { return }
        let key = connection.configuration.selected.sorted().joined(separator: ",")
        if key != selection { attempted = []; selection = key }
        let pending = Self.pending(in: storage).filter { !attempted.contains($0.id) }
        guard !pending.isEmpty else { return }
        running = true
        defer { running = false }
        var events: [CalendarMeeting] = []
        for window in Self.windows(pending) {
            guard let found = try? await connection.readMeetings(from: window.start.addingTimeInterval(-3600),
                                                                 to: window.end.addingTimeInterval(3600)) else { return }
            events += found
        }
        var matches: [UUID: CalendarRecordingMatch] = [:]
        for recording in pending {
            matches[recording.id] = CalendarMeeting.match(recordingStart: recording.start, recordingEnd: recording.end, events: events)
        }
        if storage.applyCalendarMatches(matches) { attempted.formUnion(pending.map { $0.id }) }
    }

    /// Events were added or moved: recordings that matched nothing may match now.
    func calendarChanged() { attempted = [] }

    /// Unlinked, finished meeting recordings that are not waiting for the person to choose an event.
    private static func pending(in storage: RecordingsLibraryStorage) -> [(id: UUID, start: Date, end: Date)] {
        storage.recordings.compactMap { recording in
            guard recording.type.isMeetingLike, recording.calendarMeeting == nil, recording.calendarLinkDeclined != true,
                  recording.calendarCandidates?.isEmpty != false,
                  !recording.status.isInProgressCapture, let end = recording.resolvedEndedAt, end > recording.createdAt
            else { return nil }
            return (recording.id, recording.createdAt, end)
        }
    }

    /// Recordings less than a day apart share one calendar read.
    private static func windows(_ recordings: [(id: UUID, start: Date, end: Date)]) -> [(start: Date, end: Date)] {
        var windows: [(start: Date, end: Date)] = []
        for recording in recordings.sorted(by: { $0.start < $1.start }) {
            if let last = windows.last, recording.start.timeIntervalSince(last.end) < 86400 {
                windows[windows.count - 1].end = max(last.end, recording.end)
            } else {
                windows.append((recording.start, recording.end))
            }
        }
        return windows
    }
}

// MARK: - Shortcuts actions

struct JoinNextMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Join Next Meeting"
    static let description = IntentDescription("Opens the link of the meeting that is running or starts within the next hour.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let connection = CalendarConnection.shared
        if connection.currentMeetings.isEmpty { await connection.refresh() } // Shortcuts may have just launched Diduny.
        guard let meeting = connection.currentMeetings.first(where: {
            $0.meetingURL != nil && $0.start <= Date().addingTimeInterval(3600)
        }) else {
            return .result(dialog: "No meeting with a link starts within the next hour.")
        }
        if let message = await connection.joinFromMenu(meeting, record: connection.configuration.recordOnJoin) {
            return .result(dialog: "\(message)")
        }
        return .result(dialog: "Joining \(connection.configuration.hideNames ? String(localized: "Meeting") : meeting.title).")
    }
}

struct RecordCurrentMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Current Meeting"
    static let description = IntentDescription("Starts a meeting recording linked to the calendar meeting that is running now.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let delegate = AppDelegate.current else { return .result(dialog: "Diduny is not ready yet.") }
        let state = delegate.appState.meetingRecordingState
        guard state != .recording, state != .processing else { return .result(dialog: "A meeting recording is already running.") }
        let connection = CalendarConnection.shared
        if let meeting = connection.currentMeetings.first(where: { $0.start <= Date().addingTimeInterval(300) }) {
            delegate.toggleMeetingRecording(provider: connection.configuration.localRecording ? .local : .cloud, calendarMeeting: meeting)
        } else {
            delegate.toggleMeetingRecording()
        }
        guard Self.started(after: delegate.appState.meetingRecordingState) else {
            return .result(dialog: "Diduny couldn't start the meeting recording. Finish the current recording or sign in, then try again.")
        }
        return .result(dialog: "Diduny is starting the meeting recording.")
    }

    /// A start blocked by sign-in or another recording leaves the state unchanged.
    static func started(after state: RecordingState) -> Bool { state == .processing || state == .recording }
}
