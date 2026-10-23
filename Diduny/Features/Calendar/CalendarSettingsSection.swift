import AppKit
import SwiftUI

struct CalendarSettingsSection: View {
    @State private var connection: CalendarConnection
    @State private var showConsent = false
    @State private var approved = false
    @State private var showBrowser = false
    @State private var showCalendars = false
    @State private var browsers = InstalledBrowser.discover()

    init(connection: CalendarConnection = .shared) {
        _connection = State(initialValue: connection)
    }

    var body: some View {
        Section {
            if connection.configuration.connected {
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("macOS Calendars").font(.headline)
                        Text("\(connection.calendars.filter { connection.configuration.selected.contains($0.id) }.count) selected")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Manage calendars…") { showCalendars = true }
                }.padding(.vertical, 6)
                HStack {
                    if connection.busy {
                        ProgressView().controlSize(.small)
                        Text("Refreshing calendars…").font(.caption).foregroundStyle(.secondary)
                    } else if let date = connection.fetchedAt {
                        Text("Last read: \(date.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh") { Task { await connection.refresh() } }.disabled(connection.busy)
                }
                if connection.calendars.isEmpty && !connection.busy {
                    Text("No calendars are available. Add an account in System Settings → Internet Accounts, then refresh.")
                }
            } else {
                Label("Connect your calendars", systemImage: "calendar.badge.plus").font(.headline)
                Text("Use calendars already connected to this Mac. Choose which ones appear in Diduny.")
                    .foregroundStyle(.secondary)
                Button("Connect macOS calendars…") { approved = false; showConsent = true }.buttonStyle(.borderedProminent)
            }
            if let error = connection.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Button("Open Calendar Permissions") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            }
            DisclosureGroup("Read a calendar from a browser", isExpanded: $showBrowser) {
                BrowserCalendarSettingsView()
            }
        } header: { Text("Calendars") }
        .sheet(isPresented: $showCalendars) { calendarManagement }
        .sheet(isPresented: $showConsent) {
            VStack(alignment: .leading, spacing: 18) {
                Label("Connect your calendars", systemImage: "hand.raised").font(.title2.bold())
                Text("Allow Diduny to read event titles, times, meeting links, descriptions, locations and attendees from calendars on this Mac, including after restart, until you disconnect. Choose the calendars after connecting.")
                Text("Calendar events stay in memory. Connection settings and reminder history stay on this Mac. Meeting recordings, including ones made before connecting, are linked to their calendar events automatically; the meeting's title, time, calendar, agenda, location and attendees (names and emails) are then saved with that local recording, remain after you disconnect, and are deleted with the recording. Diduny does not send your calendar to a server. Your calendar accounts continue their normal provider synchronization.")
                Text("macOS requests full calendar access; Diduny only reads calendar data. Recording requires a separate action. Local transcription is the default for calendar recordings.").foregroundStyle(.secondary)
                Toggle("I am allowed to access these calendars and approve ongoing local reading.", isOn: $approved)
                HStack {
                    Button("Cancel") { showConsent = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Connect") { showConsent = false; Task { await connection.connect() } }
                        .disabled(!approved).keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(width: 540)
        }
        if connection.configuration.connected, !connection.configuration.detailsConsent {
            Section {
                Label("Show agendas and people", systemImage: "person.2.badge.key").font(.headline)
                Text("Diduny can show each meeting's description, place and attendees in reminders and the menu, keep them (names and emails) with linked recordings on this Mac, and link your earlier meeting recordings to their calendar events automatically. Nothing is sent to a server.")
                    .foregroundStyle(.secondary)
                Button("Allow agendas and people") { Task { await connection.allowEventDetails() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        if connection.configuration.connected {
            Section("Meeting reminders") {
                Picker("When a meeting starts", selection: preference(\.reminderStyle)) {
                    Text("Full screen").tag(CalendarConfiguration.ReminderStyle.fullScreen)
                    Text("Small window").tag(CalendarConfiguration.ReminderStyle.window)
                    Text("Off").tag(CalendarConfiguration.ReminderStyle.off)
                }
                Picker("Remind me", selection: preference(\.reminderMinutes)) {
                    Text("At start time").tag(0)
                    Text("1 minute before").tag(1)
                    Text("5 minutes before").tag(5)
                    Text("15 minutes before").tag(15)
                    Text("1 hour before").tag(60)
                }
                .disabled(connection.configuration.reminderStyle == .off)
                Toggle("Show again while the meeting is running", isOn: preference(\.repeatDuringMeeting))
                    .disabled(connection.configuration.reminderStyle == .off)
                Text("Until you join or dismiss it, including after the Mac wakes or is unlocked. Full-screen reminders can always be dismissed with Escape.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Joining") {
                Picker("Open meeting links in", selection: preference(\.browserBundleID)) {
                    Text("Default browser").tag(String?.none)
                    ForEach(browsers) { browser in
                        Text(verbatim: browser.name).tag(String?.some(browser.id))
                    }
                }
                Toggle("Open Zoom and Teams in their apps", isOn: preference(\.openInApps))
                Toggle("Record when I choose Join", isOn: preference(\.recordOnJoin))
                Toggle("Transcribe calendar recordings locally", isOn: preference(\.localRecording))
                Text("Local mode saves audio if no model is ready; it never silently uploads it. To keep reminders running after login, use Launch at Login in General.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Picker("Show next meeting in menu bar", selection: preference(\.displayMinutes)) {
                    Text("15 minutes before").tag(15)
                    Text("1 hour before").tag(60)
                    Text("All day").tag(1440)
                }
                Toggle("Show tomorrow's meetings", isOn: preference(\.showTomorrow))
                Toggle("Show meetings without a link", isOn: preference(\.showWithoutLink))
                Toggle("Hide meeting names", isOn: preference(\.hideNames))
                Text("Hides titles, people and agendas in the menu bar and reminders, for example while sharing your screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var calendarManagement: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose calendars").font(.title2.bold())
                    Text("Only selected calendars appear in meetings and reminders.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { showCalendars = false }.keyboardShortcut(.defaultAction)
            }.padding(24)
            Divider()
            List {
                ForEach(calendarGroups, id: \.id) { group in
                    Section {
                        ForEach(group.calendars) { calendar in calendarToggle(calendar) }
                    } header: {
                        HStack {
                            Text(group.title).font(.headline)
                            Spacer()
                            if let calendar = group.calendars.first, group.title != calendar.sourceKind.label {
                                Text(calendar.sourceKind.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.listStyle(.inset)
            Divider()
            Text("Diduny only reads calendar events.").font(.caption).foregroundStyle(.secondary).padding(.top, 12)
            HStack {
                Button("Internet Accounts…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                }
                Spacer()
                Button("Disconnect calendars", role: .destructive) {
                    connection.disconnect(); showCalendars = false
                }
            }.padding(20)
        }.frame(width: 580, height: 520)
    }

    private var calendarGroups: [(id: String, title: String, calendars: [CalendarChoice])] {
        Dictionary(grouping: connection.calendars, by: { $0.sourceID.isEmpty ? $0.source : $0.sourceID })
            .map { id, calendars in
                (id: id, title: calendars.first?.displaySource ?? "",
                 calendars: calendars.sorted { lhs, rhs in
                     if lhs.suggested != rhs.suggested { return lhs.suggested }
                     return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                 })
            }
            .sorted { lhs, rhs in
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }

    private func calendarToggle(_ calendar: CalendarChoice) -> some View {
        Toggle(isOn: Binding(
            get: { connection.configuration.selected.contains(calendar.id) },
            set: { connection.selectCalendar(calendar.id, selected: $0) }
        )) {
            HStack(spacing: 10) {
                let rgb = calendar.colorRGB ?? 0x808080
                Circle().fill(Color(red: Double((rgb >> 16) & 255) / 255,
                                    green: Double((rgb >> 8) & 255) / 255,
                                    blue: Double(rgb & 255) / 255))
                    .frame(width: 9, height: 9).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(calendar.title)
                    Text(calendar.detailLabel).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 5)
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(Text("\(calendar.title), \(calendar.displaySource), \(calendar.detailLabel)"))
    }

    private func preference<T>(_ key: WritableKeyPath<CalendarConfiguration, T>) -> Binding<T> {
        Binding(get: { connection.configuration[keyPath: key] }, set: { value in connection.updatePreferences { $0[keyPath: key] = value } })
    }
}

/// Today's meetings around now, at the top of the menu bar menu.
struct CalendarTimelineView: View {
    static let size = CGSize(width: 320, height: 44)
    private static let inset: CGFloat = 12
    let timeline: CalendarTimeline
    var hideNames = false
    var onOpen: (() -> Void)? = nil

    @MainActor static func image(_ timeline: CalendarTimeline, appearance: NSAppearance?) -> NSImage? {
        let dark = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let renderer = ImageRenderer(content: CalendarTimelineView(timeline: timeline)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    var body: some View {
        let x = { (position: Double) in Self.inset + position * (Self.size.width - 2 * Self.inset) }
        ZStack(alignment: .topLeading) {
            ForEach(timeline.hours, id: \.position) { hour in
                Text(verbatim: String(hour.hour))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(x: x(hour.position), y: 8)
                Rectangle().fill(Color.secondary.opacity(0.3))
                    .frame(width: 1, height: 22)
                    .position(x: x(hour.position), y: 30)
            }
            ForEach(timeline.segments) { segment in
                let width = max(6, x(segment.to) - x(segment.from) - 2)
                Capsule().fill(fill(segment.phase))
                    .overlay(Capsule().strokeBorder(stroke(segment.phase), lineWidth: 1.5))
                    .frame(width: width, height: 14)
                    .help(hideNames ? "" : segment.title)
                    .position(x: x(segment.from) + 1 + width / 2, y: 30)
            }
            Capsule().fill(Color.primary)
                .frame(width: 2.5, height: 26)
                .position(x: x(timeline.now), y: 30)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Today's meetings timeline"))
        .accessibilityAddTraits(.isButton)
    }

    private func fill(_ phase: CalendarTimeline.Phase) -> Color {
        switch phase {
        case .past: .clear
        case .current: Color("BrandAccentDeep")
        case .upcoming: Color("BrandTintSoft")
        }
    }

    private func stroke(_ phase: CalendarTimeline.Phase) -> Color {
        phase == .past ? Color.secondary.opacity(0.45) : Color("BrandAccentDeep")
    }
}

struct CalendarMenuLabel: View {
    @State private var connection = CalendarConnection.shared
    var body: some View {
        if let event = connection.currentMeetings.first,
           event.start.timeIntervalSince(connection.menuClock) <= Double(connection.configuration.displayMinutes * 60) {
            let title = connection.configuration.hideNames ? String(localized: "Meeting") : String(event.title.prefix(32))
            Text(title + " · " + (event.start <= connection.menuClock ? String(localized: "Now") : "\(Int(ceil(event.start.timeIntervalSince(connection.menuClock) / 60)))m"))
        }
    }
}

/// The current or next meeting with its Join button, under the timeline in the menu bar menu.
struct NextMeetingCard: View {
    static let size = CGSize(width: 320, height: 66)
    let meeting: CalendarMeeting
    let now: Date
    let hideNames: Bool
    let recordOnJoin: Bool
    let join: (_ record: Bool) -> Void

    /// One short line: "Now · ends 12:00" or "Next · Starts in 4 min".
    private var headline: String {
        meeting.phase(at: now) == .current
            ? String(localized: "Now · ends \(meeting.end.formatted(date: .omitted, time: .shortened))")
            : String(localized: "Next") + " · " + meeting.statusLine(now: now)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: headline)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .lineLimit(1)
                Text(hideNames ? String(localized: "Meeting") : meeting.title)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(meeting.scheduleLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if meeting.meetingURL != nil {
                Button("Join") { join(recordOnJoin) }
            } else {
                Button("Record meeting") { join(true) }
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(Color("BrandAccentDeep"))
        .padding(.horizontal, 14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
    }
}
