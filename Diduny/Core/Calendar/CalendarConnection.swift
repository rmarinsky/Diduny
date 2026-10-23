import Foundation
import Observation

enum CalendarSourceKind: Sendable {
    case local, exchange, calDAV, iCloud, subscribed, birthdays, unknown

    var label: String {
        switch self {
        case .local: String(localized: "On this Mac")
        case .exchange: "Exchange"
        case .calDAV: String(localized: "CalDAV account")
        case .iCloud: "iCloud"
        case .subscribed: String(localized: "Calendar subscriptions")
        case .birthdays: String(localized: "Birthdays")
        case .unknown: String(localized: "Calendar account")
        }
    }
}

struct CalendarChoice: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let source: String
    var sourceID: String = ""
    var eligibleForSuggestion: Bool = true
    var sourceKind: CalendarSourceKind = .unknown
    var colorRGB: UInt32? = nil
    var readOnly = false
    var subscription = false
    var birthday = false
    var displaySource: String {
        let generic = ["", "default", "other", "subscribed calendars"]
        return sourceKind == .local || generic.contains(source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            ? sourceKind.label : source
    }

    var detailLabel: String {
        if birthday { return String(localized: "Birthday calendar") }
        if subscription { return String(localized: "Subscribed calendar") }
        if readOnly { return String(localized: "Read-only calendar") }
        return String(localized: "Editable calendar")
    }

    var suggested: Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Exchange can expose these as ordinary editable calendars.
        let serviceNames: Set<String> = ["birthdays", "holidays", "дні народження",
                                         "свята", "свята (україна)", "свята в україні"]
        return eligibleForSuggestion && !serviceNames.contains(name)
    }
}

struct ScheduledCalendarSnapshot: Sendable {
    let calendars: [CalendarChoice]
    let meetings: [CalendarMeeting]
}

struct CalendarConfiguration: Codable, Equatable {
    enum ReminderStyle: String, CaseIterable { case fullScreen, window, off }

    var version = 1
    var connected = false
    var selected: Set<String> = []
    var displayMinutes = 60
    var reminderMinutes = 0
    var popup = false
    var fullScreen = true
    var recordOnJoin = false
    var localRecording = true
    var repeatDuringMeeting = true
    /// nil opens meeting links with the system's default browser.
    var browserBundleID: String? = nil
    var openInApps = false
    var hideNames = false
    var showTomorrow = true
    var showWithoutLink = true
    var ledger = CalendarReminderLedger()

    var reminderStyle: ReminderStyle {
        get { fullScreen ? .fullScreen : popup ? .window : .off }
        set { fullScreen = newValue == .fullScreen; popup = newValue == .window }
    }

    init() {}

    /// Saved settings from older releases lack newer keys; each missing key keeps its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let defaults = Self()
        version = try value(.version, defaults.version)
        connected = try value(.connected, defaults.connected)
        selected = try value(.selected, defaults.selected)
        displayMinutes = try value(.displayMinutes, defaults.displayMinutes)
        reminderMinutes = try value(.reminderMinutes, defaults.reminderMinutes)
        popup = try value(.popup, defaults.popup)
        fullScreen = try value(.fullScreen, defaults.fullScreen)
        recordOnJoin = try value(.recordOnJoin, defaults.recordOnJoin)
        localRecording = try value(.localRecording, defaults.localRecording)
        repeatDuringMeeting = try value(.repeatDuringMeeting, defaults.repeatDuringMeeting)
        browserBundleID = try container.decodeIfPresent(String.self, forKey: .browserBundleID)
        openInApps = try value(.openInApps, defaults.openInApps)
        hideNames = try value(.hideNames, defaults.hideNames)
        showTomorrow = try value(.showTomorrow, defaults.showTomorrow)
        showWithoutLink = try value(.showWithoutLink, defaults.showWithoutLink)
        ledger = try value(.ledger, defaults.ledger)
    }
}

@MainActor @Observable final class CalendarConnection {
    private(set) var configuration = CalendarConfiguration()
    private(set) var calendars: [CalendarChoice] = []
    private(set) var meetings: [CalendarMeeting] = []
    private(set) var fetchedAt: Date?
    private(set) var menuClock = Date()
    private(set) var busy = false
    private(set) var error: String?
    var onJoin: ((CalendarMeeting, Bool, Bool) -> Void)?
    var onReminder: (([CalendarMeeting]) -> Void)?
    private let defaults: UserDefaults
    private let authorize: () async throws -> Bool
    private let read: (Set<String>?) async throws -> ScheduledCalendarSnapshot
    private var generation = UUID()
    private var polling: Task<Void, Never>?
    private static let key = "calendar.connection.v1"

    init(defaults: UserDefaults, authorize: @escaping () async throws -> Bool,
         read: @escaping (Set<String>?) async throws -> ScheduledCalendarSnapshot) {
        self.defaults = defaults; self.authorize = authorize; self.read = read
        if let data = defaults.data(forKey: Self.key) {
            if let saved = try? JSONDecoder().decode(CalendarConfiguration.self, from: data), saved.version == 1 {
                configuration = saved
            } else { error = String(localized: "The saved calendar connection could not be restored. Connect again.") }
        }
    }

    func connect() async {
        guard !busy, !configuration.connected else { return }
        generation = UUID(); let request = generation
        busy = true; error = nil
        do {
            guard try await authorize() else {
                if request == generation { busy = false; error = String(localized: "Calendar access was not granted. Allow Diduny in System Settings → Privacy & Security → Calendars, then connect again.") }
                return
            }
            guard request == generation else { return }
            configuration.connected = true
            persist()
            busy = false
            await refresh(selectInitialCalendars: true)
        } catch {
            guard request == generation else { return }
            busy = false; self.error = error.localizedDescription
        }
    }

    func disconnect() {
        generation = UUID(); configuration = CalendarConfiguration()
        defaults.removeObject(forKey: Self.key)
        meetings = []; calendars = []; fetchedAt = nil; busy = false; error = nil
    }

    func selectCalendar(_ id: String, selected: Bool) {
        guard calendars.contains(where: { $0.id == id }) else { return }
        if selected { configuration.selected.insert(id) } else { configuration.selected.remove(id) }
        meetings.removeAll { !configuration.selected.contains($0.calendarID) }
        persist()
        Task { await refresh() }
    }

    func updatePreferences(_ update: (inout CalendarConfiguration) -> Void) {
        update(&configuration)
        configuration.displayMinutes = max(0, min(1440, configuration.displayMinutes))
        configuration.reminderMinutes = max(0, min(60, configuration.reminderMinutes))
        persist()
    }

    func refresh(selectInitialCalendars: Bool = false) async {
        guard configuration.connected, !busy else { return }
        let request = generation
        busy = true
        do {
            let snapshot = try await read(selectInitialCalendars ? nil : configuration.selected)
            guard request == generation, configuration.connected else { return }
            calendars = snapshot.calendars
            fetchedAt = Date(); error = nil; busy = false
            if selectInitialCalendars {
                configuration.selected = Set(calendars.filter(\.suggested).map(\.id)); persist()
            }
            meetings = snapshot.meetings.filter { configuration.selected.contains($0.calendarID) }
            deliverReminders()
        } catch {
            guard request == generation else { return }
            busy = false; self.error = error.localizedDescription
            fetchedAt = nil // Old rows remain visible, but cannot trigger reminders or Join.
        }
    }

    private var hasFreshSnapshot: Bool {
        guard configuration.connected, let fetchedAt else { return false }
        return (0...300).contains(Date().timeIntervalSince(fetchedAt))
    }

    var currentMeetings: [CalendarMeeting] {
        guard hasFreshSnapshot else { return [] }
        return meetings.filter { configuration.selected.contains($0.calendarID) && $0.canRemind && $0.end > Date() }
            .sorted { $0.start < $1.start }
    }

    /// Unlike `currentMeetings`, keeps ended meetings so the menu can show the whole day.
    var agendaMeetings: [CalendarMeeting] {
        guard hasFreshSnapshot else { return [] }
        return meetings.filter { configuration.selected.contains($0.calendarID) && $0.canRemind }
    }

    @discardableResult
    func join(_ meeting: CalendarMeeting, record: Bool) -> Bool {
        guard let current = currentMeetings.first(where: { $0.id == meeting.id }),
              current.start == meeting.start, current.meetingURL == meeting.meetingURL,
              current.meetingURL.map(CalendarMeeting.isJoinURL) ?? record,
              let onJoin else { return false }
        acknowledge([current])
        onJoin(current, record, configuration.localRecording)
        return true
    }

    /// Joined or dismissed: the meeting-now screen is not offered again for this occurrence.
    func acknowledge(_ meetings: [CalendarMeeting]) {
        guard !meetings.isEmpty else { return }
        for meeting in meetings { configuration.ledger.acknowledge(meeting, at: Date()) }
        persist()
    }

    func snooze(_ meetings: [CalendarMeeting], minutes: Int) {
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        for meeting in meetings { configuration.ledger.snooze(meeting, until: until) }
        persist()
    }

    /// The call detector saw a call: meetings running now or starting within five minutes count as joined.
    func acknowledgeMeetingsInProgress(now: Date = Date()) {
        acknowledge(currentMeetings.filter { $0.start <= now.addingTimeInterval(300) && $0.end > now })
    }

    /// After wake or unlock a meeting that is still running and not joined is offered again.
    func resetReminderSession() {
        configuration.ledger.resetSession()
        deliverReminders()
    }

    private(set) var isScreenLocked = false

    func setScreenLocked(_ locked: Bool) {
        let unlocked = isScreenLocked && !locked
        isScreenLocked = locked
        if unlocked { resetReminderSession() }
    }

    @discardableResult
    func joinFromMenu(_ meeting: CalendarMeeting, record: Bool) async -> String? {
        if !hasFreshSnapshot {
            await refresh()
        }
        guard hasFreshSnapshot else {
            return String(localized: "Calendar access could not be refreshed. Open Calendar settings and try again.")
        }
        guard join(meeting, record: meeting.meetingURL == nil || record) else {
            return String(localized: "This meeting changed or is no longer available. Reopen the Diduny menu and select it again.")
        }
        return nil
    }

    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    self.menuClock = Date()
                    if self.fetchedAt == nil || Date().timeIntervalSince(self.fetchedAt!) >= 60 { await self.refresh() }
                    self.deliverReminders()
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    func stop() { polling?.cancel(); polling = nil; generation = UUID(); busy = false }

    private func deliverReminders() {
        guard let onReminder, configuration.reminderStyle != .off, !isScreenLocked else { return }
        let due = configuration.ledger.due(meetings, selected: configuration.selected, now: Date(),
                                          fetchedAt: fetchedAt, leadMinutes: configuration.reminderMinutes,
                                          repeatDuringMeeting: configuration.repeatDuringMeeting)
        guard !due.isEmpty else { return }
        persist()
        onReminder(due)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: Self.key) }
    }
}
