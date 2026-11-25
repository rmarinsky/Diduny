import SwiftUI

/// The three parts of Meetings settings. Calendar is the page you land on from the sidebar.
enum MeetingSettingsTab: String, CaseIterable, Identifiable {
    case calendar
    case recording
    case notes

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .calendar: "Calendar"
        case .recording: "Recording"
        case .notes: "Notes"
        }
    }
}

/// Calendar, how a meeting is recorded, and notes. One tab at a time; nothing moves to another page.
struct MeetingSettingsView: View {
    @AppStorage(ModeDefaults.meetingTranscriptModeKey) private var startsInRaw = ModeDefaults.newInstallStartsIn.rawValue
    @State private var tab = MeetingSettingsTab.calendar

    var body: some View {
        PageScaffold(
            title: "Meetings",
            subtitle: "Calendar, recording and notes for a meeting.",
            scrollIdentity: tab,
            pinned: AnyView(tabs)
        ) {
            switch tab {
            case .calendar:
                CalendarSettingsSection()
            case .recording:
                recording
            case .notes:
                NotesSettingsView(embedded: true)
            }
        }
        .onAppear(perform: applyRequestedTab)
        .onChange(of: MainWindowController.shared.requestedMeetingsTab) { _, _ in
            applyRequestedTab()
        }
    }

    /// Stays under the title while the tab scrolls. `fixedSize` keeps it to the width of the three labels.
    private var tabs: some View {
        Picker("Meetings", selection: $tab) {
            ForEach(MeetingSettingsTab.allCases) { item in
                Text(item.label).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.top, DS.Space.md)
        .accessibilityIdentifier("meetings.tabs")
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 0) {
            AudioSettingsGroup(title: "Engine") { engineRow }
            AudioSettingsView(embedded: true)
            SpeakerLabelsGroup()
        }
    }

    /// Notes settings, and the buttons that open them, set this before the page appears.
    private func applyRequestedTab() {
        guard let requested = MainWindowController.shared.requestedMeetingsTab else { return }
        tab = requested
        MainWindowController.shared.requestedMeetingsTab = nil
    }

    /// Decision 12: the meeting engine lives in Modes > Meeting; this row shows it and opens it.
    private var engineRow: some View {
        SettingsLineRow(
            title: "Meeting engine",
            caption: "Choose the engine and its details in Modes.",
            kind: .button,
            showsHairline: false
        ) {
            Text(verbatim: startsInTitle).foregroundStyle(DS.Palette.secondary)
            Button("Open Modes") {
                MainWindowController.shared.requestedModesExpander = .meeting
                MainWindowController.shared.showWindow(section: .modes)
            }
            .buttonStyle(.bordered)
        }
    }

    private var startsInTitle: String {
        switch MeetingSegment(rawValue: startsInRaw) ?? ModeDefaults.newInstallStartsIn {
        case .thisMac: String(localized: "Local")
        case .cloud: String(localized: "Cloud")
        case .recordOnly: String(localized: "Record only")
        }
    }
}

#Preview {
    MeetingSettingsView()
        .frame(width: 450, height: 550)
}
