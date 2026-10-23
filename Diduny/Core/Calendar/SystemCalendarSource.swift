import AppKit
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
        let choices = calendars.map { calendar in
            let kind: CalendarSourceKind
            switch calendar.source.sourceType {
            case .local: kind = .local
            case .exchange: kind = .exchange
            case .calDAV: kind = .calDAV
            case .mobileMe: kind = .iCloud
            case .subscribed: kind = .subscribed
            case .birthdays: kind = .birthdays
            @unknown default: kind = .unknown
            }
            let rgb = calendar.color.map(Self.rgb)
            return CalendarChoice(id: calendar.calendarIdentifier, title: calendar.title, source: calendar.source.title,
                                  sourceID: calendar.source.sourceIdentifier,
                                  eligibleForSuggestion: calendar.type != .birthday && !calendar.isSubscribed && calendar.allowsContentModifications,
                                  sourceKind: kind, colorRGB: rgb, readOnly: !calendar.allowsContentModifications,
                                  subscription: calendar.isSubscribed, birthday: calendar.type == .birthday)
        }
        let included = selected ?? Set(choices.filter(\.suggested).map(\.id))
        let now = Date()
        let meetings = events(in: calendars.filter { included.contains($0.calendarIdentifier) },
                              from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(7 * 86400))
        return ScheduledCalendarSnapshot(calendars: choices, meetings: meetings)
    }

    /// Meetings in the selected calendars for an arbitrary range, used to link past recordings.
    /// EventKit limits one query to four years, so longer ranges are read in yearly chunks.
    func readMeetings(selected: Set<String>, from: Date, to: Date) throws -> [CalendarMeeting] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw Failure.accessDenied }
        let calendars = store.calendars(for: .event).filter { selected.contains($0.calendarIdentifier) }
        var meetings: [CalendarMeeting] = []
        var chunkStart = from
        while chunkStart < to {
            let chunkEnd = min(to, chunkStart.addingTimeInterval(365 * 86400))
            meetings += events(in: calendars, from: chunkStart, to: chunkEnd)
            chunkStart = chunkEnd
        }
        var seen = Set<String>()
        return meetings.filter { seen.insert($0.id).inserted }
    }

    private func events(in calendars: [EKCalendar], from: Date, to: Date) -> [CalendarMeeting] {
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate).compactMap { event -> CalendarMeeting? in
            guard let calendar = event.calendar, let start = event.startDate, let end = event.endDate,
                  !event.calendarItemIdentifier.isEmpty else { return nil }
            let occurrence = (event.hasRecurrenceRules || event.isDetached)
                ? String((event.occurrenceDate ?? start).timeIntervalSince1970) : "single"
            let id = calendar.calendarIdentifier + "/" + event.calendarItemIdentifier + "/" + occurrence
            let url = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
                .compactMap { CalendarMeeting.joinURL(in: $0) }.first
            var attendees = (event.attendees ?? []).map { Self.attendee($0, organizer: false) }
            if let organizer = event.organizer {
                let entry = Self.attendee(organizer, organizer: true)
                if let index = attendees.firstIndex(where: { $0.email != nil && $0.email == entry.email }) {
                    attendees[index].isOrganizer = true
                } else {
                    attendees.insert(entry, at: 0)
                }
            }
            let me = attendees.first(where: \.isCurrentUser)
            return CalendarMeeting(id: id, calendarID: calendar.calendarIdentifier,
                                   title: event.title ?? "Untitled event", start: start, end: end, meetingURL: url,
                                   cancelled: event.status == .canceled,
                                   declined: me?.response == .declined,
                                   allDay: event.isAllDay,
                                   notes: CalendarMeeting.cleanedNotes(event.notes),
                                   location: event.location?.nilIfBlank,
                                   attendees: attendees.isEmpty ? nil : attendees,
                                   calendarTitle: calendar.title,
                                   calendarColorRGB: calendar.color.map(Self.rgb),
                                   eventIdentifier: event.eventIdentifier,
                                   lastModified: event.lastModifiedDate,
                                   myResponse: me?.response)
        }
    }

    private static func attendee(_ participant: EKParticipant, organizer: Bool) -> CalendarAttendee {
        let address = participant.url.absoluteString
        let email = address.lowercased().hasPrefix("mailto:") ? String(address.dropFirst(7)).removingPercentEncoding : nil
        let response: CalendarAttendee.Response = switch participant.participantStatus {
        case .accepted, .delegated, .completed: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending, .inProcess: .pending
        default: .unknown
        }
        return CalendarAttendee(name: participant.name?.nilIfBlank, email: email?.nilIfBlank, response: response,
                                isOrganizer: organizer, isCurrentUser: participant.isCurrentUser)
    }

    private static func rgb(_ color: NSColor) -> UInt32 {
        guard let color = color.usingColorSpace(.deviceRGB) else { return 0x808080 }
        return (UInt32(max(0, min(255, color.redComponent * 255))) << 16) |
            (UInt32(max(0, min(255, color.greenComponent * 255))) << 8) |
            UInt32(max(0, min(255, color.blueComponent * 255)))
    }
}

extension CalendarConnection {
    static let shared: CalendarConnection = {
        let source = SystemCalendarSource()
        return CalendarConnection(defaults: .standard, authorize: { try await source.authorize() },
                                  read: { try await source.read(selected: $0) })
    }()
}
