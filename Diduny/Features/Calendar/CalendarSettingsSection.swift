import SwiftUI

struct CalendarSettingsSection: View {
    @State private var connection = CalendarConnection.shared
    @State private var showConsent = false
    @State private var approved = false
    @State private var showBrowser = false
    @State private var showCalendars = false
    @State private var showUpcoming = false

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
                Text("Allow Diduny to read event titles, times and meeting links from calendars on this Mac, including after restart, until you disconnect. Choose the calendars after connecting.")
                Text("Calendar events stay in memory. Connection settings and reminder history stay on this Mac. When you record a meeting, its calendar reference is saved with the local recording. Diduny does not send your calendar to a server. Your calendar accounts continue their normal provider synchronization.")
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
            Section("Calendar reminders") {
                Picker("Show next meeting in menu bar", selection: preference(\.displayMinutes)) {
                    Text("15 minutes before").tag(15)
                    Text("1 hour before").tag(60)
                    Text("All day").tag(1440)
                }
                Picker("Remind me", selection: preference(\.reminderMinutes)) {
                    Text("At start time").tag(0)
                    Text("5 minutes before").tag(5)
                    Text("15 minutes before").tag(15)
                    Text("1 hour before").tag(60)
                }
                Toggle("Show a reminder pop-up", isOn: preference(\.popup))
                Toggle("Show a full-screen reminder", isOn: preference(\.fullScreen))
                Toggle("Record when I choose Join", isOn: preference(\.recordOnJoin))
                Toggle("Transcribe calendar recordings locally", isOn: preference(\.localRecording))
                Text("Full-screen reminders can always be dismissed with Escape. Local mode saves audio if no model is ready; it never silently uploads it. To keep reminders running after login, use Launch at Login in General.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Upcoming meetings", isExpanded: $showUpcoming) {
                    if connection.currentMeetings.isEmpty {
                        Text("No upcoming timed events in the selected calendars.").foregroundStyle(.secondary)
                    }
                    ForEach(connection.currentMeetings.prefix(3)) { meeting in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(meeting.title).lineLimit(1)
                                Text(meeting.start.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(meeting.meetingURL == nil ? "Record meeting" : "Join") {
                                connection.join(meeting, record: meeting.meetingURL == nil || connection.configuration.recordOnJoin)
                            }
                            .buttonStyle(.link)
                            .help(meeting.meetingURL?.absoluteString ?? meeting.title)
                            .accessibilityLabel(Text("\(meeting.meetingURL == nil ? String(localized: "Record meeting") : String(localized: "Join")): \(meeting.title)"))
                            .accessibilityHint(Text(meeting.meetingURL?.host ?? ""))
                        }.padding(.vertical, 4)
                    }
                    Text("The next three meetings are shown here. More meetings are available in the menu bar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
    @State private var connection = CalendarConnection.shared
    var body: some View {
        if connection.configuration.connected {
            Menu("Upcoming meetings") {
                if connection.currentMeetings.isEmpty { Text("No upcoming meetings") }
                ForEach(connection.currentMeetings.prefix(15)) { event in
                    Button((event.meetingURL == nil ? String(localized: "Record meeting") + " · " : "") + event.start.formatted(date: .omitted, time: .shortened) + " · " + event.title) {
                        connection.join(event, record: event.meetingURL == nil || connection.configuration.recordOnJoin)
                    }
                }
                Divider()
                Button("Calendar settings…") { MainWindowController.shared.showWindow(section: .meetings) }
            }
            Divider()
        }
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
