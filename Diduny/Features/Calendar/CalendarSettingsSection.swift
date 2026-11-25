import AppKit
import SwiftUI

struct CalendarSettingsSection: View {
    @State private var connection: CalendarConnection
    @State private var showConsent = false
    /// Re-renders the "Starts in" line when it changes anywhere.
    @AppStorage(ModeDefaults.meetingTranscriptModeKey) private var startsInRaw = ModeDefaults.newInstallStartsIn.rawValue
    @AppStorage(ModeDefaults.calendarStartsInKey) private var calendarStartsInRaw: String?
    @State private var approved = false
    @State private var showCalendars = false
    @State private var browsers = InstalledBrowser.discover()

    init(connection: CalendarConnection = .shared) {
        _connection = State(initialValue: connection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AudioSettingsGroup(title: "Calendars") { calendarRows }
            AudioSettingsGroup(title: "Browser") { BrowserCalendarSettingsView() }
            if connection.configuration.connected {
                AudioSettingsGroup(title: "Reminders") { reminderRows }
                AudioSettingsGroup(title: "Joining") { joiningRows }
                AudioSettingsGroup(title: "Menu bar") { menuBarRows }
            }
        }
        .sheet(isPresented: $showCalendars) { calendarManagement }
        .sheet(isPresented: $showConsent) {
            VStack(alignment: .leading, spacing: 18) {
                Label("Connect your calendars", systemImage: "hand.raised").font(.title2.bold())
                Text("Allow Diduny to read event titles, times, meeting links, descriptions, locations and attendees from calendars on this Mac, including after restart, until you disconnect. Choose the calendars after connecting.")
                Text("Calendar events stay in memory. Connection settings and reminder history stay on this Mac. Meeting recordings, including ones made before connecting, are linked to their calendar events automatically; the meeting's title, time, calendar, agenda, location and attendees (names and emails) are then saved with that local recording, remain after you disconnect, and are deleted with the recording. Diduny does not send your calendar to a server. Only a meeting's title and attendee names go to Diduny Cloud with its recording, and you can turn that off in Vocabulary & context. Your calendar accounts continue their normal provider synchronization.")
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
    }

    @ViewBuilder private var calendarRows: some View {
        if connection.configuration.connected {
            let selected = connection.calendars.filter { connection.configuration.selected.contains($0.id) }.count
            SettingsLineRow(title: "macOS Calendars", caption: "\(selected) selected", kind: .button) {
                Button("Manage calendars…") { showCalendars = true }
                    .buttonStyle(.bordered)
            }
            SettingsLineRow(title: "Refresh", caption: refreshCaption, kind: .button) {
                if connection.busy { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await connection.refresh() } }
                    .buttonStyle(.bordered)
                    .disabled(connection.busy)
            }
            if connection.calendars.isEmpty && !connection.busy {
                EmptyState(
                    icon: "calendar.badge.exclamationmark",
                    title: "No calendars",
                    message: "No calendars are available. Add an account in System Settings → Internet Accounts, then refresh.",
                    compact: true
                )
            }
            SettingsLineRow(
                title: "Show agendas and people",
                caption: "Reads each meeting's description, place and attendees for reminders and the menu, keeps them (names and emails) with linked recordings on this Mac, and links earlier meeting recordings to their events. Only a meeting's title and attendee names go to Diduny Cloud with its recording, and you can turn that off in Vocabulary & context.",
                kind: .toggle
            ) {
                SettingsSwitch(title: "Show agendas and people", isOn: Binding(
                    get: { connection.configuration.eventDetails },
                    set: { enabled in Task { await connection.setEventDetails(enabled) } }))
            }
        } else {
            EmptyState(
                icon: "calendar.badge.plus",
                title: "Connect your calendars",
                message: "Use calendars already connected to this Mac. Choose which ones appear in Diduny.",
                compact: true
            ) {
                Button("Connect macOS calendars…") { approved = false; showConsent = true }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Palette.accent)
            }
        }
        if let error = connection.error {
            Banner(message: Text(verbatim: error)) {
                Button("Open Calendar Permissions") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var refreshCaption: LocalizedStringKey? {
        if connection.busy { return "Refreshing calendars…" }
        guard let date = connection.fetchedAt else { return nil }
        return "Last read: \(date.formatted(date: .omitted, time: .standard))"
    }

    @ViewBuilder private var reminderRows: some View {
        SettingsLineRow(
            title: "Before a meeting",
            caption: "A small window in the middle of the screen with the meeting's details.",
            kind: .popUp
        ) {
            Picker("Before a meeting", selection: preference(\.reminderMinutes)) {
                Text("Off").tag(0)
                Text("1 minute before").tag(1)
                Text("5 minutes before").tag(5)
                Text("15 minutes before").tag(15)
                Text("1 hour before").tag(60)
            }.labelsHidden().fixedSize()
        }
        SettingsLineRow(title: "When a meeting starts", kind: .popUp) {
            Picker("When a meeting starts", selection: preference(\.reminderStyle)) {
                Text("Full screen").tag(CalendarConfiguration.ReminderStyle.fullScreen)
                Text("Small window").tag(CalendarConfiguration.ReminderStyle.window)
                Text("Off").tag(CalendarConfiguration.ReminderStyle.off)
            }.labelsHidden().fixedSize()
        }
        SettingsLineRow(
            title: "Show again while the meeting is running",
            caption: "Until you join or dismiss it, including after the Mac wakes or is unlocked. Full-screen reminders can always be dismissed with Escape.",
            kind: .toggle,
            showsHairline: false
        ) {
            SettingsSwitch(title: "Show again while the meeting is running", isOn: preference(\.repeatDuringMeeting))
        }
        .disabled(connection.configuration.reminderStyle == .off)
    }

    @ViewBuilder private var joiningRows: some View {
        SettingsLineRow(title: "Open meeting links in", kind: .popUp) {
            Picker("Open meeting links in", selection: preference(\.browserBundleID)) {
                Text("Default browser").tag(String?.none)
                ForEach(browsers) { browser in
                    Text(verbatim: browser.name).tag(String?.some(browser.id))
                }
            }.labelsHidden().fixedSize()
        }
        SettingsLineRow(title: "Open Zoom and Teams in their apps", kind: .toggle) {
            SettingsSwitch(title: "Open Zoom and Teams in their apps", isOn: preference(\.openInApps))
        }
        SettingsLineRow(title: "Record when I choose Join", kind: .toggle) {
            SettingsSwitch(title: "Record when I choose Join", isOn: preference(\.recordOnJoin))
        }
        // Calendar meetings follow Settings › Modes › Meeting "From calendar"; shown, not edited, here.
        SettingsLineRow(
            title: "Transcribe calendar recordings",
            caption: "Calendar meetings follow Settings › Modes › Meeting.",
            kind: .button,
            showsHairline: false
        ) {
            Text(verbatim: startsInTitle).foregroundStyle(DS.Palette.secondary)
            Button("Open Modes") { AppDelegate.current?.openMainWindow(section: .modes) }
                .buttonStyle(.link)
                .accessibilityIdentifier("calendar.startsIn.openModes")
        }
    }

    @ViewBuilder private var menuBarRows: some View {
        SettingsLineRow(title: "Show next meeting in menu bar", kind: .popUp) {
            Picker("Show next meeting in menu bar", selection: preference(\.displayMinutes)) {
                Text("15 minutes before").tag(15)
                Text("1 hour before").tag(60)
                Text("All day").tag(1440)
            }.labelsHidden().fixedSize()
        }
        SettingsLineRow(title: "Show tomorrow's meetings", kind: .toggle) {
            SettingsSwitch(title: "Show tomorrow's meetings", isOn: preference(\.showTomorrow))
        }
        SettingsLineRow(title: "Show meetings without a link", kind: .toggle) {
            SettingsSwitch(title: "Show meetings without a link", isOn: preference(\.showWithoutLink))
        }
        SettingsLineRow(
            title: "Hide meeting names",
            caption: "Hides titles, people and agendas in the menu bar and reminders, for example while sharing your screen.",
            kind: .toggle,
            showsHairline: false
        ) {
            SettingsSwitch(title: "Hide meeting names", isOn: preference(\.hideNames))
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

    private var startsInTitle: String {
        switch MeetingSegment(rawValue: calendarStartsInRaw ?? startsInRaw) ?? ModeDefaults.newInstallStartsIn {
        case .thisMac: String(localized: "Local")
        case .cloud: String(localized: "Cloud")
        case .recordOnly: String(localized: "Record only")
        }
    }

    private func preference<T>(_ key: WritableKeyPath<CalendarConfiguration, T>) -> Binding<T> {
        Binding(get: { connection.configuration[keyPath: key] }, set: { value in connection.updatePreferences { $0[keyPath: key] = value } })
    }
}

/// Today's meetings around now, at the top of the menu bar menu.
struct CalendarTimelineView: View {
    private static let width: CGFloat = 320
    private static let inset: CGFloat = 12
    private static let laneStep: CGFloat = 17
    static func size(_ timeline: CalendarTimeline) -> CGSize {
        CGSize(width: width, height: 44 + extraHeight(timeline))
    }
    private static func extraHeight(_ timeline: CalendarTimeline) -> CGFloat { CGFloat(timeline.lanes - 1) * laneStep }
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
        let x = { (position: Double) in Self.inset + position * (Self.width - 2 * Self.inset) }
        let extra = Self.extraHeight(timeline)
        ZStack(alignment: .topLeading) {
            ForEach(timeline.hours, id: \.position) { hour in
                Text(verbatim: String(hour.hour))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(x: x(hour.position), y: 8)
                Rectangle().fill(Color.secondary.opacity(0.3))
                    .frame(width: 1, height: 22 + extra)
                    .position(x: x(hour.position), y: 30 + extra / 2)
            }
            ForEach(timeline.segments) { segment in
                let width = max(6, x(segment.to) - x(segment.from) - 2)
                Capsule().fill(fill(segment.phase))
                    .overlay(Capsule().strokeBorder(stroke(segment.phase), lineWidth: 1.5))
                    .frame(width: width, height: 14)
                    .help(hideNames ? "" : segment.title)
                    .position(x: x(segment.from) + 1 + width / 2, y: 30 + CGFloat(segment.lane) * Self.laneStep)
            }
            Capsule().fill(Color.primary)
                .frame(width: 2.5, height: 26 + extra)
                .position(x: x(timeline.now), y: 30 + extra / 2)
        }
        .frame(width: Self.width, height: Self.size(timeline).height)
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
            Text(title + " · " + event.shortCountdown(now: connection.menuClock))
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
            // Nothing to join days ahead: the button appears ten minutes before the start.
            if meeting.isJoinable(now: now) {
                if meeting.meetingURL != nil {
                    Button("Join") { join(recordOnJoin) }
                } else {
                    Button("Record meeting") { join(true) }
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(Color("BrandAccentDeep"))
        .padding(.horizontal, 14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
    }
}
