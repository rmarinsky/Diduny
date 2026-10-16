import ApplicationServices
import SwiftUI

struct BrowserCalendarSettingsView: View {
    @ObservedObject private var connection = BrowserCalendarConnection.shared
    @State private var browsers: [InstalledBrowser] = []
    @State private var browserID = "com.google.Chrome"
    @State private var profileID = ""
    @State private var outlook = false
    @State private var consent = false
    @State private var approved = false
    private var browser: InstalledBrowser? { browsers.first { $0.id == browserID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browser reading uses the visible calendar tab. It is not a complete calendar subscription and does not schedule reminders. For reminders and recording links, connect macOS calendars above.")
                .font(.callout).foregroundStyle(.secondary)
            if connection.connected, let saved = connection.saved {
                Label(saved.profileName, systemImage: "person.crop.circle")
                Text(saved.calendarURL.host ?? "").font(.caption)
                HStack {
                    Button("Read now") { connection.read(force: true) }.disabled(connection.busy)
                    Button("Disconnect browser", role: .destructive) { connection.disconnect() }
                }
            } else {
                Picker("Browser", selection: $browserID) {
                    Text("Choose a browser").tag("")
                    ForEach(browsers) { Text($0.name).tag($0.id) }
                }.onChange(of: browserID) { _, _ in profileID = "" }
                Picker("Profile", selection: $profileID) {
                    Text("Choose a profile").tag("")
                    ForEach(browser?.profiles ?? []) { Text($0.name).tag($0.id) }
                }
                Picker("Calendar", selection: $outlook) {
                    Text("Google Calendar").tag(false)
                    Text("Outlook").tag(true)
                }
                HStack {
                    Button("Refresh browsers") { Task { await discover() } }
                    Button("Open calendar") {
                        guard let browser else { return }
                        connection.openCalendar(browser: browser, profileID: profileID, url: URL(string: outlook
                            ? "https://outlook.cloud.microsoft/calendar/view/week" : "https://calendar.google.com/calendar/u/0/r")!)
                    }.disabled(profileID.isEmpty || connection.busy)
                    Button("Connect this window…") { approved = false; consent = true }
                        .disabled(profileID.isEmpty || connection.busy)
                }
            }
            if !AXIsProcessTrusted() {
                Button("Allow Accessibility in System Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                Text("macOS grants broad interface access. Diduny reads only the approved calendar window.").font(.caption)
            }
            Text(connection.message).font(.caption).textSelection(.enabled)
            if let result = connection.result {
                Text("Last read: \(result.snapshot.readAt.formatted(date: .omitted, time: .standard)) · \(result.snapshot.events.count) visible rows")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show event titles and full meeting links", isOn: $connection.reveal)
                Text("Rows may repeat. The visible page is not the full calendar.").font(.caption)
                ForEach(Array(result.snapshot.events.prefix(30).enumerated()), id: \.offset) { index, event in
                    VStack(alignment: .leading) {
                        Text(connection.reveal ? event.title : "Event \(index + 1)").font(.headline)
                        Text(event.displayedDate + " · " + event.displayedTime).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(result.snapshot.meetingLinks, id: \.absoluteString) { url in
                    Text(connection.reveal ? url.absoluteString : (url.host ?? "Meeting link")).textSelection(.enabled).font(.caption)
                }
            }
        }.padding(.vertical, 8)
        .task { await discover() }
        .sheet(isPresented: $consent) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Read this browser calendar").font(.title2.bold())
                Text("Allow Diduny to read titles, dates, times and meeting links from this window every minute, including after restart, until you disconnect. This includes accounts you switch to in this window. The browser must remain open with the calendar tab selected.")
                Text("Diduny names this window to recognize it later. Browser, profile, calendar view address, window name and consent time are saved locally. Events and meeting links remain in memory. No passwords, cookies or authorization tokens are copied. Calendar data is not sent to Diduny servers.")
                Text("Chrome and Edge are verified browser families. Other browsers and profile layouts may be unsupported. A missing or changed window pauses reading.").foregroundStyle(.secondary)
                Toggle("I am allowed to read these calendars and approve ongoing local access.", isOn: $approved)
                HStack {
                    Button("Cancel") { consent = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Connect") {
                        guard let profile = browser?.profiles.first(where: { $0.id == profileID }) else { return }
                        consent = false; connection.connect(browserID: browserID, profileName: profile.name)
                    }.disabled(!approved).keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(width: 540)
        }
    }
    private func discover() async {
        browsers = await Task.detached { InstalledBrowser.discover() }.value
    }
}
