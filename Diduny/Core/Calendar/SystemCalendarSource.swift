import EventKit
import Foundation

/// EventKit objects never leave this actor. Only value snapshots reach the UI.
actor SystemCalendarSource {
    private let store = EKEventStore()

    enum Failure: LocalizedError {
        case accessDenied
        var errorDescription: String? { "Calendar access is unavailable. Allow Diduny in System Settings → Privacy & Security → Calendars." }
    }

    func authorize() async throws -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return try await store.requestFullAccessToEvents()
    }

    func read(selected: Set<String>?) throws -> ScheduledCalendarSnapshot {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw Failure.accessDenied }
        let calendars = store.calendars(for: .event)
        let choices = calendars.map {
            CalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title,
                           sourceID: $0.source.sourceIdentifier,
                           eligibleForSuggestion: $0.type != .birthday && !$0.isSubscribed && $0.allowsContentModifications)
        }
        let included = selected ?? Set(choices.filter(\.suggested).map(\.id))
        let selectedCalendars = calendars.filter { included.contains($0.calendarIdentifier) }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-86400),
                                                end: now.addingTimeInterval(7 * 86400), calendars: selectedCalendars)
        let events = selectedCalendars.isEmpty ? [] : store.events(matching: predicate)
        let meetings = events.compactMap { event -> CalendarMeeting? in
            guard let calendar = event.calendar, let start = event.startDate, let end = event.endDate,
                  !event.calendarItemIdentifier.isEmpty else { return nil }
            let occurrence = (event.hasRecurrenceRules || event.isDetached)
                ? String((event.occurrenceDate ?? start).timeIntervalSince1970) : "single"
            let id = calendar.calendarIdentifier + "/" + event.calendarItemIdentifier + "/" + occurrence
            let url = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
                .compactMap { CalendarMeeting.joinURL(in: $0) }.first
            return CalendarMeeting(id: id, calendarID: calendar.calendarIdentifier,
                                   title: event.title ?? "Untitled event", start: start, end: end, meetingURL: url,
                                   cancelled: event.status == .canceled,
                                   declined: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false,
                                   allDay: event.isAllDay)
        }
        return ScheduledCalendarSnapshot(calendars: choices, meetings: meetings)
    }
}

extension CalendarConnection {
    static let shared: CalendarConnection = {
        let source = SystemCalendarSource()
        return CalendarConnection(defaults: .standard, authorize: { try await source.authorize() },
                                  read: { try await source.read(selected: $0) })
    }()
}
