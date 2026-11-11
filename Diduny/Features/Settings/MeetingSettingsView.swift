import SwiftUI

struct MeetingSettingsView: View {
    var body: some View {
        PageScaffold(title: "Calendar & meetings", scrolls: false) { formContent }
    }

    private var formContent: some View {
        Form {
            CalendarSettingsSection()
            Section {
                Button("Meeting audio and transcription…") {
                    // Decision 12: meeting settings live in Modes > Meeting.
                    MainWindowController.shared.requestedModesExpander = .meeting
                    MainWindowController.shared.showWindow(section: .modes)
                }
            } footer: {
                Text("Choose the engine, audio sources and recording levels in Modes.")
            }
            MeetingNotesSection()
        }.formStyle(.grouped)
    }
}

/// Notes after a meeting: the same stored values as on the Notes settings page.
private struct MeetingNotesSection: View {
    @State private var timing = NotesSettings.meetingTiming
    @State private var useCalendarNames = NotesSettings.useCalendarNames

    var body: some View {
        Section {
            Picker("Write notes", selection: $timing) {
                ForEach(NotesMeetingTiming.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Names from the calendar event", isOn: $useCalendarNames)
            Button("Open Notes settings") { MainWindowController.shared.showWindow(section: .notesSettings) }
        } header: {
            Text("Notes after a meeting")
        } footer: {
            Text(NotesSettings.writer == .off
                ? "Nobody writes notes yet. Choose a model or a subscription tool in Notes settings."
                : "Notes are written by \(NotesSettings.writer.label).")
        }
        .onChange(of: timing) { _, value in NotesSettings.meetingTiming = value }
        .onChange(of: useCalendarNames) { _, value in NotesSettings.useCalendarNames = value }
    }
}

#Preview {
    MeetingSettingsView()
        .frame(width: 450, height: 550)
}
