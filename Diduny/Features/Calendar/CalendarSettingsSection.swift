import AppKit
import SwiftUI

struct CalendarSettingsSection: View {
    @State private var connection: CalendarConnection
    @State private var showConsent = false
    @State private var approved = false
    @State private var showBrowser = false
    @State private var showCalendars = false
    @State private var browsers = InstalledBrowser.all()

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
                Text("Calendar events stay in memory. Connection settings and reminder history stay on this Mac. When a recording is linked to a meeting, the meeting's title, time, calendar, agenda, location and attendees (names and emails) are saved with that local recording, remain after you disconnect, and are deleted with the recording. Diduny does not send your calendar to a server. Your calendar accounts continue their normal provider synchronization.")
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

struct CalendarMenuItems: View {
    @State private var connection: CalendarConnection

    init(connection: CalendarConnection = .shared) {
        _connection = State(initialValue: connection)
    }
    var body: some View {
        if connection.configuration.connected {
            let now = connection.menuClock
            let meetings = connection.agendaMeetings
            if let timeline = CalendarTimelineView.image(CalendarTimeline(meetings: meetings, now: now),
                                                         appearance: NSApp?.effectiveAppearance) {
                Button { MainWindowController.shared.showWindow(section: .meetings) } label: {
                    Image(nsImage: timeline).renderingMode(.original)
                }
                .accessibilityLabel(Text("Today's meetings timeline"))
            }
            let agenda = CalendarMeeting.agenda(meetings, now: now)
            if agenda.isEmpty { Text("No upcoming meetings") }
            ForEach(agenda) { day in
                Section(dayTitle(day.day, now: now)) {
                    ForEach(day.meetings) { row($0, now: now) }
                }
            }
            if agenda.isEmpty { Divider() } // A section already ends with a separator.
            Button("Calendar settings…") { MainWindowController.shared.showWindow(section: .meetings) }
            Divider()
        }
    }

    /// Ended meetings are plain disabled items: AppKit enables any item that has a submenu.
    @ViewBuilder private func row(_ event: CalendarMeeting, now: Date) -> some View {
        let title = event.title.count > 40 ? String(event.title.prefix(39)) + "…" : event.title
        let label = Label {
            Text(verbatim: event.start.formatted(date: .omitted, time: .shortened) + " – " +
                event.end.formatted(date: .omitted, time: .shortened) + "   " + title)
        } icon: {
            Image(systemName: event.meetingURL == nil ? "person.2.fill" : "video.fill")
        }
        if event.phase(at: now) == .past {
            Button {} label: { label }.disabled(true)
        } else {
            Menu {
                if let url = event.meetingURL {
                    Button("Join") { join(event, record: connection.configuration.recordOnJoin) }
                    if !connection.configuration.recordOnJoin {
                        Button("Join and record") { join(event, record: true) }
                    }
                    Divider()
                    Button("Copy meeting link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                } else {
                    Button("Record meeting") { join(event, record: true) }
                }
            } label: { label }
        }
    }

    private func dayTitle(_ day: Date, now: Date) -> String {
        let date = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return Calendar.current.isDate(day, inSameDayAs: now)
            ? String(localized: "Today (\(date))") : String(localized: "Tomorrow (\(date))")
    }

    private func join(_ event: CalendarMeeting, record: Bool) {
        Task {
            if let message = await connection.joinFromMenu(event, record: record) {
                DictationOverlayController.shared.showInfo(message: message, duration: 5)
            }
        }
    }
}

/// The menu cannot host custom views, so the timeline reaches it as a rendered image.
struct CalendarTimelineView: View {
    static let size = CGSize(width: 300, height: 44)
    private static let inset: CGFloat = 12
    let timeline: CalendarTimeline

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
                    .position(x: x(segment.from) + 1 + width / 2, y: 30)
            }
            Capsule().fill(Color.primary)
                .frame(width: 2.5, height: 26)
                .position(x: x(timeline.now), y: 30)
        }
        .frame(width: Self.size.width, height: Self.size.height)
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
            Text(String(event.title.prefix(32)) + " · " + (event.start <= connection.menuClock ? String(localized: "Now") : "\(Int(ceil(event.start.timeIntervalSince(connection.menuClock) / 60)))m"))
        }
    }
}

/// Apps that open web links, for "Open meeting links in".
struct InstalledBrowser: Identifiable, Equatable {
    let id: String
    let name: String

    static func all() -> [InstalledBrowser] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { url -> InstalledBrowser? in
            guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return InstalledBrowser(id: id, name: FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: ""))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
