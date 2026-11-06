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
        }.formStyle(.grouped)
    }
}

#Preview {
    MeetingSettingsView()
        .frame(width: 450, height: 550)
}
