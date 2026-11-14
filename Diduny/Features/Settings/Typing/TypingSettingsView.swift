import PapugaKit
import SwiftUI

/// Settings > Typing > Layout fixes: fixes text typed in the wrong keyboard layout (the Papuga engine).
struct TypingSettingsView: View {
    @State private var model: TypingSettingsModel
    private let presenter: FloatingSurfacePresenter

    init(model: TypingSettingsModel? = nil, presenter: FloatingSurfacePresenter = .shared) {
        _model = State(initialValue: model ?? TypingSettingsModel())
        self.presenter = presenter
    }

    var body: some View {
        PageScaffold(title: "Layout fixes", subtitle: "Fixes text typed in the wrong keyboard layout.") {
            VStack(alignment: .leading, spacing: 0) {
                statusRow
                fixRows
                group("Apps")
                SettingsLineRow(
                    title: "Apps where fixes are off",
                    caption: LocalizedStringKey(model.appsCaption),
                    kind: .button
                ) {
                    TypingAppsButton(model: model, presenter: presenter)
                }
                .accessibilityIdentifier("typing.apps")
                group("Typing speed")
                SettingsLineRow(
                    title: "Typing speed",
                    caption: "Used to count the time saved in Overview.",
                    kind: .button,
                    showsHairline: false
                ) {
                    Text("\(String(format: "%.0f", model.typingSpeedWordsPerMinute)) WPM")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("typing.typingSpeed")
                    Button("Typing test") { MainWindowController.shared.showWindow(section: .typingTest) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("typing.typingTest")
                }
            }
        }
        .onAppear { model.reload() }
        // Accessibility may have been allowed in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .typingSpeedSettingsChanged)) { _ in
            model.reload()
        }
    }

    /// Group heading (spec 4.10): 18 above, 15 semibold, 2 below, as on General.
    private func group(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(DS.Font.groupHeading)
            .foregroundStyle(DS.Palette.text)
            .padding(.top, 18)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var statusRow: some View {
        switch model.status {
        case .accessibilityNeeded:
            SettingsLineRow(
                title: "Accessibility",
                caption: "Needed to fix what you type. Not allowed yet.",
                kind: .button
            ) {
                Button("Open System Settings") {
                    PermissionManager.shared.openSystemSettingsForPermission(.accessibility)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("typing.accessibility.open")
            }
            .accessibilityIdentifier("typing.status.accessibility")
        case .startFailed:
            SettingsLineRow(title: "Diduny could not start watching the keyboard.", kind: .button) {
                Button("Try again") { model.tryAgain() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("typing.startFailed.tryAgain")
            }
            .accessibilityIdentifier("typing.status.startFailed")
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var fixRows: some View {
        SettingsLineRow(title: "Fix wrong-layout text as I type", kind: .toggle) {
            SettingsSwitch(title: "Fix wrong-layout text as I type", isOn: Binding(
                get: { model.enabled }, set: { model.setEnabled($0) }
            ))
            .accessibilityIdentifier("typing.enabled")
        }
        Group {
            SettingsLineRow(
                title: "How often to fix",
                caption: "Careful fixes only clear cases. More hints asks before unclear ones.",
                kind: .segmented
            ) {
                Picker("How often to fix", selection: Binding(
                    get: { model.sensitivity }, set: { model.setSensitivity($0) }
                )) {
                    Text("Careful").tag(AutoFixSensitivityPreset.careful)
                    Text("Balanced").tag(AutoFixSensitivityPreset.balanced)
                    Text("More hints").tag(AutoFixSensitivityPreset.moreHints)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("typing.sensitivity")
            }
            SettingsLineRow(title: "Switch the keyboard layout after a fix", kind: .toggle) {
                SettingsSwitch(title: "Switch the keyboard layout after a fix", isOn: Binding(
                    get: { model.switchLayoutAfterFix }, set: { model.setSwitchLayoutAfterFix($0) }
                ))
                .accessibilityIdentifier("typing.switchLayoutAfterFix")
            }
            SettingsLineRow(title: "Show an undo hint at the cursor", kind: .toggle) {
                SettingsSwitch(title: "Show an undo hint at the cursor", isOn: Binding(
                    get: { model.undoHintEnabled }, set: { model.setUndoHintEnabled($0) }
                ))
                .accessibilityIdentifier("typing.undoHintEnabled")
            }
        }
        .disabled(model.optionsDisabled)
        // The row labels dim with their controls.
        .opacity(model.optionsDisabled ? DS.Field.disabledOpacity : 1)
    }
}

/// "Change": opens the apps popup on its floating surface, hung from the button.
private struct TypingAppsButton: View {
    let model: TypingSettingsModel
    let presenter: FloatingSurfacePresenter

    @State private var anchor = FloatingSurfaceAnchor()

    var body: some View {
        Button("Change") {
            guard let frame = anchor.screenFrame else { return }
            model.reload()
            presenter.togglePopup(
                owner: "typing.apps.change", name: "typing.apps", anchor: frame, parent: anchor.window,
                fromKeyboard: false
            ) { close in
                TypingAppsPopup(model: model, onClose: close)
            }
        }
        .floatingSurfaceAnchor(anchor)
        .accessibilityIdentifier("typing.apps.change")
    }
}

/// The apps popup: the languages Change popup (design-spec 4.9) with apps. Each tick is written at once.
struct TypingAppsPopup: View {
    let model: TypingSettingsModel
    let onClose: () -> Void

    @State private var query = ""

    var body: some View {
        PopupShell(
            icon: "macwindow", title: String(localized: "Apps where fixes are off"),
            subtitle: String(localized: "Diduny does not change what you type in these apps"),
            search: $query, bodyStyle: .list, onClose: onClose
        ) {
            let rows = ChangeLanguagesRows(
                chosen: model.disabledApps, all: model.appIDs, query: query, name: model.appName
            )
            VStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    PickerMenuGroupHeader(title: PickerMenuModel.nothingFoundTitle, identifier: "popup.empty")
                }
                if !rows.chosen.isEmpty {
                    PickerMenuGroupHeader(title: String(localized: "Fixes are off in"), identifier: "popup.group.chosen")
                    ForEach(rows.chosen, id: \.self) { tickRow($0, isChosen: true) }
                }
                if !rows.rest.isEmpty {
                    PickerMenuGroupHeader(title: String(localized: "Other apps"), identifier: "popup.group.all")
                    ForEach(rows.rest, id: \.self) { tickRow($0, isChosen: false) }
                }
            }
        }
    }

    private func tickRow(_ bundleID: String, isChosen: Bool) -> some View {
        ChangeTickRow(name: model.appName(bundleID), code: bundleID, isChosen: isChosen, isEnabled: true) {
            model.toggleApp(bundleID)
        }
    }
}
