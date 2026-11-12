import KeyboardShortcuts
import SwiftUI

/// The other shortcuts as rows of the Settings > Modes & shortcuts table (design-spec 7.15, 05 §2.5):
/// the keys sit in the Shortcut column, presses and the switch in the second column.
struct ShortcutsSettingsView: View {
    @State private var model: ShortcutsSettingsModel
    @State private var recordingRow: ShortcutRow?
    let widths: (engine: CGFloat, second: CGFloat)

    /// - Parameter store: nil reads the stored shortcuts (`SettingsShortcutsStore`).
    @MainActor
    init(store: ShortcutsSettingsStore? = nil, widths: (engine: CGFloat, second: CGFloat)) {
        _model = State(initialValue: ShortcutsSettingsModel(store: store ?? SettingsShortcutsStore()))
        self.widths = widths
    }

    /// Every item but "Open Settings", which cannot be changed.
    private static let items = ShortcutsSettingsModel.groups.flatMap(\.items).filter { $0 != .openSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.items) { item in
                row(item)
                Rectangle().fill(DS.Palette.line).frame(height: 1)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder private func row(_ item: ShortcutsSettingsModel.Item) -> some View {
        switch item {
        case let .shortcut(row):
            gridRow(title: Self.title(of: row), caption: Self.caption(of: row)) {
                controls(row)
            } keys: {
                keysField(row, isOn: model.isEnabled(row)).disabled(!model.isEnabled(row))
            }
            if row == .inplaceTranslation, model.inplaceBlocked {
                Text("Unavailable while modifier-key shortcuts use both Option keys or both Command keys.")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
                    .padding(.leading, ModesGrid.detailIndent)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("shortcuts.inplaceTranslation.blocked")
            }
        case .keepAudioWhenCancelled:
            gridRow(title: "Keep the audio when cancelled", caption: nil) {
                SettingsSwitch(
                    title: "Keep the audio when cancelled",
                    isOn: Binding(get: { model.keepsAudioWhenCancelled }, set: { model.keepsAudioWhenCancelled = $0 })
                )
                .accessibilityIdentifier("shortcuts.escapeCancelSaveAudio")
            } keys: { EmptyView() }
        case .inplacePair:
            gridRow(
                title: "Translate in place between",
                caption: "Works in both directions: the direction follows the language of the selected text."
            ) {
                pairPicker
            } keys: { EmptyView() }
        case .openSettings:
            EmptyView()
        }
    }

    /// Name and caption across the Mode and Engine columns, then the second column, then the Shortcut column.
    private func gridRow(
        title: LocalizedStringKey, caption: LocalizedStringKey?,
        @ViewBuilder second: () -> some View, @ViewBuilder keys: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: ModesGrid.gap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(DS.Font.body).foregroundStyle(DS.Palette.text)
                if let caption {
                    Text(caption).font(DS.Font.meta).foregroundStyle(DS.Palette.secondary)
                }
            }
            .frame(width: ModesGrid.modeColumn + ModesGrid.gap + widths.engine, alignment: .leading)
            HStack(spacing: DS.Space.sm) { second() }
                .frame(width: widths.second, alignment: .leading)
            ZStack(alignment: .leading) {
                Color.clear.frame(height: 1)
                keys().fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: ModesGrid.shortcutColumn, alignment: .leading)
            Color.clear.frame(width: DS.Size.expander, height: 1)
        }
        .frame(minHeight: ModesGrid.cellMinHeight)
        .padding(.vertical, ModesGrid.rowPadding)
    }

    /// 1× 2× 3× and the switch (spec 4.14). Switch off: keys and count disabled at 0.45.
    @ViewBuilder private func controls(_ row: ShortcutRow) -> some View {
        let isOn = model.isEnabled(row)
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
                #if TEST_BUILD
                    UITestCaptureTrace.recordingRow = recordingRow.map { "\($0)" }
                #endif
            }
        )
        let rowLabel = String(localized: Self.titleResource(of: row))
        return ShortcutField(
            shortcut: model.keys(for: row),
            rowLabel: rowLabel,
            isRecording: isRecording.wrappedValue,
            isOff: !isOn
        )
        .overlay {
            Group {
                if let name = row.shortcutName {
                    ShortcutRecorderOverlay(name: name, isRecording: isRecording) {
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
        // Field and recorder are one element, so the field is the element at its own point
        // (hittable); otherwise the invisible recorder answers there.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("\(rowLabel) shortcut"))
        .accessibilityValue(Text(verbatim: isRecording.wrappedValue
                ? String(localized: "Press keys...")
                : ShortcutField.spokenName(model.keys(for: row) ?? "", locale: .current)))
        .accessibilityIdentifier(row.keysIdentifier)
        // VoiceOver (and an accessibility press) starts recording as a click does.
        .accessibilityAction {
            guard isOn, let name = row.shortcutName else { return }
            NotificationCenter.default.post(name: ShortcutRecorderOverlay.startRecordingNotification, object: name.rawValue)
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
    ShortcutsSettingsView(store: FakePreviewShortcutsStore(), widths: (engine: 200, second: 180))
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
