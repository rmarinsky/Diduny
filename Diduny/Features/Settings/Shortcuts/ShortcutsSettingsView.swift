import KeyboardShortcuts
import SwiftUI

/// Settings > Shortcuts (design-spec 7.15, 05 §2.5, prototype.html:750-753). Mode shortcuts and
/// push-to-talk keys live in Settings > Modes.
struct ShortcutsSettingsView: View {
    @State private var model: ShortcutsSettingsModel
    @State private var recordingRow: ShortcutRow?

    /// - Parameter store: nil reads the stored shortcuts (`SettingsShortcutsStore`).
    @MainActor
    init(store: ShortcutsSettingsStore? = nil) {
        _model = State(initialValue: ShortcutsSettingsModel(store: store ?? SettingsShortcutsStore()))
    }

    var body: some View {
        PageScaffold(
            title: "Shortcuts",
            subtitle: "Each one has its keys, how many times you press them, and a switch. Shortcuts that start a mode are in Modes."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ShortcutsSettingsModel.groups) { group in
                    Text(Self.title(of: group.id))
                        .font(DS.Font.groupHeading)
                        .foregroundStyle(DS.Palette.text)
                        .padding(.top, 18)
                    ForEach(group.items) { item in
                        row(item)
                    }
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder private func row(_ item: ShortcutsSettingsModel.Item) -> some View {
        switch item {
        case let .shortcut(row):
            SettingsLineRow(title: Self.title(of: row), caption: Self.caption(of: row), kind: .segmented) {
                shortcutCluster(row)
            }
            if row == .inplaceTranslation, model.inplaceBlocked {
                Text("Unavailable while modifier-key shortcuts use both Option keys or both Command keys.")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("shortcuts.inplaceTranslation.blocked")
            }
        case .keepAudioWhenCancelled:
            SettingsLineRow(title: "Keep the audio when cancelled", kind: .toggle) {
                SettingsSwitch(
                    title: "Keep the audio when cancelled",
                    isOn: Binding(get: { model.keepsAudioWhenCancelled }, set: { model.keepsAudioWhenCancelled = $0 })
                )
                .accessibilityIdentifier("shortcuts.escapeCancelSaveAudio")
            }
        case .inplacePair:
            SettingsLineRow(
                title: "Translate in place between",
                caption: "Works in both directions: the direction follows the language of the selected text.",
                kind: .popUp
            ) {
                pairPicker
            }
        case .openSettings:
            SettingsLineRow(
                title: "Open Settings",
                caption: "The standard macOS shortcut. It cannot be changed.",
                kind: .button
            ) {
                ShortcutField(shortcut: "⌘,", rowLabel: String(localized: "Open Settings"))
                    .disabled(true)
                    .accessibilityIdentifier("shortcuts.openSettings.keys")
            }
        }
    }

    /// Keys field, 1× 2× 3×, switch (spec 4.14). Switch off: field and count disabled at 0.45.
    @ViewBuilder private func shortcutCluster(_ row: ShortcutRow) -> some View {
        let isOn = model.isEnabled(row)
        keysField(row, isOn: isOn)
            .disabled(!isOn)
        ShortcutPressCountPicker(
            selection: Binding(
                get: { model.displayedPressCount(for: row) },
                set: { model.setPressCount($0, for: row) }
            ),
            isOff: !isOn,
            disabledCounts: Set(ShortcutsSettingsModel.pressCounts.filter { !model.isPressCountSelectable($0, for: row) })
        )
        .disabled(!isOn)
        .accessibilityIdentifier(row.pressCountIdentifier)
        SettingsSwitch(
            title: Self.title(of: row),
            isOn: Binding(get: { model.isEnabled(row) }, set: { model.setEnabled($0, for: row) })
        )
        .disabled(row == .inplaceTranslation && model.inplaceBlocked)
        .accessibilityIdentifier(row.enabledIdentifier)
    }

    private func keysField(_ row: ShortcutRow, isOn: Bool) -> some View {
        let isRecording = Binding(
            get: { recordingRow == row },
            set: { recording in
                if recording { recordingRow = row } else if recordingRow == row { recordingRow = nil }
            }
        )
        let rowLabel = String(localized: Self.titleResource(of: row))
        return ShortcutField(
            shortcut: model.keys(for: row),
            rowLabel: rowLabel,
            isRecording: isRecording.wrappedValue,
            isOff: !isOn
        )
        // A recorder row's overlay is the accessibility element (`ShortcutRecorderOverlay`).
        .accessibilityHidden(row.shortcutName != nil)
        .accessibilityIdentifier(row.keysIdentifier)
        .overlay {
            Group {
                if let name = row.shortcutName {
                    ShortcutRecorderOverlay(
                        name: name,
                        isRecording: isRecording,
                        accessibility: .init(
                            identifier: row.keysIdentifier,
                            label: String(localized: "\(rowLabel) shortcut"),
                            value: isRecording.wrappedValue
                                ? String(localized: "Press keys...")
                                : ShortcutField.spokenName(model.keys(for: row) ?? "", locale: .current),
                            isEnabled: isOn
                        )
                    ) {
                        model.shortcutDidChange(row)
                    }
                } else {
                    ShortcutCaptureOverlay(
                        mode: row == .cancelRecording ? .singleKey : .chordOrModifiers,
                        takenShortcuts: { model.store.takenShortcuts(excluding: row) },
                        isRecording: isRecording
                    ) { captured in
                        model.saveCaptured(captured, for: row)
                    }
                }
            }
            .allowsHitTesting(isOn)
        }
    }

    private var pairPicker: some View {
        Picker(
            "Translate in place between",
            selection: Binding(
                get: { model.selectedPairID ?? "" },
                set: { model.selectPair(id: $0) }
            )
        ) {
            ForEach(model.pairOptions) { pair in
                Text(verbatim: pair.fullName()).tag(pair.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .disabled(model.pairOptions.isEmpty)
        .accessibilityIdentifier("shortcuts.inplaceTranslationPair")
    }

    // MARK: - Copy (spec 8.9)

    private static func title(of group: ShortcutsSettingsModel.GroupID) -> LocalizedStringKey {
        switch group {
        case .whileRecording: "While recording"
        case .text: "Text"
        case .app: "App"
        }
    }

    private static func titleResource(of row: ShortcutRow) -> LocalizedStringResource {
        switch row {
        case .cancelRecording: "Cancel recording"
        case .forceSubmit: "Stop, paste and send"
        case .addMeetingChapter: "Add a meeting chapter"
        case .translateSelectedText: "Translate selected text"
        case .inplaceTranslation: "Translate the selection in place"
        case .historyPalette: "History palette"
        }
    }

    private static func title(of row: ShortcutRow) -> LocalizedStringKey {
        LocalizedStringKey(titleResource(of: row).key)
    }

    private static func caption(of row: ShortcutRow) -> LocalizedStringKey? {
        switch row {
        case .forceSubmit: "Stops, pastes, then presses ⌘↩."
        case .translateSelectedText: "Opens the translation window with the selection."
        case .inplaceTranslation: "Replaces the selected text with its translation."
        case .cancelRecording, .addMeetingChapter, .historyPalette: nil
        }
    }
}

#Preview {
    ShortcutsSettingsView(store: FakePreviewShortcutsStore())
        .frame(width: 757, height: 760)
}

/// Preview data only.
@MainActor
private final class FakePreviewShortcutsStore: ShortcutsSettingsStore {
    func keys(for row: ShortcutRow) -> String? {
        ["escapeCancel": "Esc", "forceSubmit": "⌘↩", "addMeetingChapter": "⌥⌘B", "translateSelectedText": "⌥⌘T",
         "inplaceTranslation": "⌥⌘", "toggleHistoryPalette": "⌥⌘H"][row.identifierName]
    }

    func pressCount(for row: ShortcutRow) -> Int { row == .cancelRecording || row == .inplaceTranslation ? 2 : 1 }
    func setPressCount(_: Int, for _: ShortcutRow) {}
    func isEnabled(_: ShortcutRow) -> Bool { true }
    func setEnabled(_: Bool, for _: ShortcutRow) {}
    func shortcutDidChange(_: ShortcutRow) {}
    func saveCaptured(_: ShortcutCaptureMachine.Captured, for _: ShortcutRow) {}
    func takenShortcuts(excluding _: ShortcutRow) -> [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] { [:] }
    var keepsAudioWhenCancelled = true
    var inplaceUsesModifierChord: Bool { true }
    var inplaceBlockedByPushToTalk: Bool { false }
    var offeredPairs: [TranslationLanguagePair] { [TranslationLanguagePair(languageA: "en", languageB: "uk")] }
    var currentPair: TranslationLanguagePair? { offeredPairs.first }
    func selectPair(_: TranslationLanguagePair) {}
}
