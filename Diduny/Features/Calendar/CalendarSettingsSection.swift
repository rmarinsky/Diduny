import SwiftUI

struct CalendarSettingsSection: View {
    @State private var connection = CalendarConnection.shared
    @State private var showConsent = false
    @State private var approved = false
    @State private var showBrowser = false

    var body: some View {
        Section {
            Label("Your calendars, on this Mac", systemImage: "calendar.badge.clock").font(.headline)
            Text("Connect Google, Microsoft, iCloud or CalDAV calendars already added to macOS. No Diduny OAuth registration is required.")
                .foregroundStyle(.secondary)
            if connection.configuration.connected {
                HStack {
                    Button("Refresh calendars") { Task { await connection.refresh() } }.disabled(connection.busy)
                    Button("Disconnect calendars", role: .destructive) { connection.disconnect() }
                    if connection.busy { ProgressView().controlSize(.small) }
                }
                if let date = connection.fetchedAt {
                    Text("Last read: \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(connection.calendars) { calendar in
                    Toggle(isOn: Binding(get: { connection.configuration.selected.contains(calendar.id) },
                                         set: { connection.selectCalendar(calendar.id, selected: $0) })) {
                        VStack(alignment: .leading) {
                            Text(calendar.title)
                            Text(calendar.source).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if connection.calendars.isEmpty && !connection.busy {
                    Text("No calendars are available. Add an account in System Settings → Internet Accounts, then refresh.")
                }
            } else {
                Button("Connect macOS calendars…") { approved = false; showConsent = true }.buttonStyle(.borderedProminent)
            }
            if let error = connection.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Button("Open Internet Accounts") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
            }
            DisclosureGroup("Read a calendar from a browser", isExpanded: $showBrowser) {
                BrowserCalendarSettingsView()
            }
        } header: { Text("Calendars") }
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
            Section("Upcoming meetings") {
                if connection.currentMeetings.isEmpty { Text("No upcoming timed events in the selected calendars.").foregroundStyle(.secondary) }
                ForEach(connection.currentMeetings.prefix(30)) { meeting in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title).font(.headline)
                            Text(meeting.start.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                            if let url = meeting.meetingURL { Text(url.absoluteString).font(.caption).textSelection(.enabled) }
                        }
                        Spacer()
                        Button(meeting.meetingURL == nil ? "Record meeting" : "Join") {
                            connection.join(meeting, record: meeting.meetingURL == nil || connection.configuration.recordOnJoin)
                        }
                    }
                }
                Text("Updates follow macOS account synchronization. Diduny rereads on changes and every minute; it cannot guarantee provider delivery latency.").font(.caption).foregroundStyle(.secondary)
            }
        }
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
