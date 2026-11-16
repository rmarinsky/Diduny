import SwiftUI

/// The layout shortcuts on Settings > Typing, next to the fixes they control: "Switch layout of selected
/// text" (a modifier pair pressed together 2x or 3x) and "Undo the last layout fix".
struct TypingShortcutRows: View {
    @State private var model: ShortcutsSettingsModel
    @State private var isRecordingUndo = false

    /// - Parameter store: nil reads the stored shortcuts (`SettingsShortcutsStore`).
    @MainActor
    init(store: ShortcutsSettingsStore? = nil) {
        _model = State(initialValue: ShortcutsSettingsModel(store: store ?? SettingsShortcutsStore()))
    }

    var body: some View {
        convertRow
        undoRow
    }

    private var convertRow: some View {
        SettingsLineRow(
            title: "Switch layout of selected text",
            caption: "Two modifier keys pressed together. 1× is off for them.",
            kind: .segmented
        ) {
            ShortcutPressCountPicker(
                selection: Binding(get: { model.convertPressCount }, set: { model.convertPressCount = $0 }),
                isOff: !model.convertEnabled,
                disabledCounts: [1]
            )
            .disabled(!model.convertEnabled)
            .accessibilityIdentifier("shortcuts.convertLayout.pressCount")
            Picker(
                "Keys to convert",
                selection: Binding(get: { model.convertPair }, set: { model.convertPair = $0 })
            ) {
                ForEach(TypingConvertPair.allCases) { pair in
                    Text(verbatim: pair.families.displaySymbols).tag(pair)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(!model.convertEnabled)
            .accessibilityIdentifier("shortcuts.convertLayout.keys")
            SettingsSwitch(
                title: "Switch layout of selected text",
                isOn: Binding(get: { model.convertEnabled }, set: { model.convertEnabled = $0 })
            )
            .accessibilityIdentifier("shortcuts.convertLayout.enabled")
        }
    }

    private var undoRow: some View {
        let row = ShortcutRow.undoLayoutFix
        let isOn = model.isEnabled(row)
        let label = String(localized: "Undo the last layout fix")
        return SettingsLineRow(
            title: "Undo the last layout fix",
            caption: "No keys by default. Click the field and press the keys you want.",
            kind: .button,
            showsHairline: false
        ) {
            ShortcutField(shortcut: model.keys(for: row), rowLabel: label, isRecording: isRecordingUndo, isOff: !isOn)
                .overlay {
                    if let name = row.shortcutName {
                        ShortcutRecorderOverlay(name: name, isRecording: $isRecordingUndo) {
                            model.shortcutDidChange(row)
                        }
                        .allowsHitTesting(isOn)
                    }
                }
                .accessibilityIdentifier(row.keysIdentifier)
            SettingsSwitch(
                title: "Undo the last layout fix",
                isOn: Binding(get: { model.isEnabled(row) }, set: { model.setEnabled($0, for: row) })
            )
            .accessibilityIdentifier(row.enabledIdentifier)
        }
    }
}
