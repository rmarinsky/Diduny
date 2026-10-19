import Foundation
import Observation

struct CalendarChoice: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let source: String
    var sourceID: String = ""
    var eligibleForSuggestion: Bool = true

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
    var version = 1
    var connected = false
    var selected: Set<String> = []
    var displayMinutes = 60
    var reminderMinutes = 5
    var popup = true
    var fullScreen = false
    var recordOnJoin = false
    var localRecording = true
    var ledger = CalendarReminderLedger()
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

    var currentMeetings: [CalendarMeeting] {
        guard configuration.connected, let fetchedAt, Date().timeIntervalSince(fetchedAt) >= 0, Date().timeIntervalSince(fetchedAt) <= 300 else { return [] }
        return meetings.filter { configuration.selected.contains($0.calendarID) && $0.canRemind && $0.end > Date() }
            .sorted { $0.start < $1.start }
    }

    func join(_ meeting: CalendarMeeting, record: Bool) {
        guard let current = currentMeetings.first(where: { $0.id == meeting.id }),
              current.start == meeting.start, current.meetingURL == meeting.meetingURL,
              current.meetingURL.map(CalendarMeeting.isJoinURL) ?? record else { return }
        onJoin?(current, record, configuration.localRecording)
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
        guard let onReminder, configuration.popup || configuration.fullScreen else { return }
        let due = configuration.ledger.due(meetings, selected: configuration.selected, now: Date(),
                                          fetchedAt: fetchedAt, leadMinutes: configuration.reminderMinutes)
        guard !due.isEmpty else { return }
        persist()
        onReminder(due)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: Self.key) }
    }
}
