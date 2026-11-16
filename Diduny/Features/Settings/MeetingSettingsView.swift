import SwiftUI

/// One page in the order a meeting happens: before (calendar, browser, reminders), during (engine,
/// sound, speaker labels), after (notes). Composes the existing sections; nothing is collapsed.
struct MeetingSettingsView: View {
    @AppStorage(ModeDefaults.meetingTranscriptModeKey) private var startsInRaw = ModeDefaults.newInstallStartsIn.rawValue

    var body: some View {
        PageScaffold(title: "Meetings", subtitle: "Before, during and after a meeting, in the order it happens.") {
            VStack(alignment: .leading, spacing: 0) {
                phase("Before", "Calendar, browser and reminders", first: true)
                CalendarSettingsSection()

                phase("During", "Engine and sound")
                AudioSettingsGroup(title: "Engine") { engineRow }
                AudioSettingsView(embedded: true)
                SpeakerLabelsGroup()

                phase("After", "Notes")
                NotesSettingsView(embedded: true)
            }
        }
    }

    private func phase(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, first: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Text(title).font(DS.Font.settingsTitle)
            Text(detail).font(DS.Font.body).foregroundStyle(DS.Palette.secondary)
        }
        .padding(.top, first ? 0 : 36)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
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
