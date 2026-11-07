import SwiftUI

/// Settings > Languages (design-spec 7.13, 05 §2.3). Wired into the sidebar by WP-50.
struct LanguagesSettingsView: View {
    @State private var model: LanguagesSettingsModel
    private let presenter: FloatingSurfacePresenter

    init(model: LanguagesSettingsModel? = nil, presenter: FloatingSurfacePresenter = .shared) {
        _model = State(initialValue: model ?? LanguagesSettingsModel())
        self.presenter = presenter
    }

    var body: some View {
        PageScaffold(title: "Languages", subtitle: "The languages you speak and the ones you translate into.") {
            VStack(alignment: .leading, spacing: 0) {
                group("Languages you speak", first: true)
                SettingsLineRow(
                    title: LocalizedStringKey(LanguagesSettingsModel.listText(model.speak)),
                    caption: "Sent to the engine as a hint. Suggested from your keyboard layouts. With none chosen the engine detects the language.",
                    kind: .button,
                    titleIdentifier: "languages.speak"
                ) {
                    ChangeButton(list: .speak, model: model, presenter: presenter)
                }

                group("Your languages")
                SettingsLineRow(
                    title: LocalizedStringKey(LanguagesSettingsModel.listText(model.yourLanguages)),
                    caption: "Shown first and in crimson in every Translate into menu and language list.",
                    kind: .button,
                    titleIdentifier: "languages.yours"
                ) {
                    ChangeButton(list: .yourLanguages, model: model, presenter: presenter)
                }
                targetRow
                pairRow

                group("Voice commands")
                voiceRows
            }
        }
        .onAppear { model.reload() }
    }

    private func group(_ title: LocalizedStringKey, first: Bool = false) -> some View {
        Text(title)
            .font(DS.Font.groupHeading)
            .foregroundStyle(DS.Palette.text)
            // `.main h3` margin 22 0 8 (P:133).
            .padding(.top, first ? 0 : 22)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private var targetRow: some View {
        SettingsLineRow(
            title: "Translate into, by default",
            caption: "For dictation and the translation window. One language.",
            kind: .popUp
        ) {
            Picker("Translate into, by default", selection: Binding(
                get: { model.defaultTarget }, set: { model.setDefaultTarget($0) }
            )) {
                ForEach(model.targetOptions, id: \.self) { code in
                    Text(verbatim: LanguagesSettingsModel.name(code)).tag(code)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("languages.defaultTarget")
        }
    }

    @ViewBuilder private var pairRow: some View {
        if let pair = model.pair {
            SettingsLineRow(
                title: "Pair for both directions",
                caption: "For Translate meeting and Translate in place: each language is translated into the other.",
                kind: .popUp
            ) {
                Picker("Pair for both directions", selection: Binding(
                    get: { pair.id }, set: { model.selectPair(id: $0) }
                )) {
                    ForEach(model.pairs) { Text(verbatim: $0.fullName()).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("languages.pair")
            }
        } else {
            // 05 §2.3 proposal: one language, no pair.
            SettingsLineRow(
                title: "Pair for both directions",
                caption: "Add a second language to Your languages",
                kind: .button
            ) {
                ChangeButton(list: .yourLanguages, model: model, presenter: presenter, identifier: "languages.pair.change")
            }
            .accessibilityIdentifier("languages.pair.needSecond")
        }
    }

    @ViewBuilder private var voiceRows: some View {
        SettingsLineRow(
            title: "Translate by voice",
            caption: "Say \"translate into Polish\" while you dictate. Diduny Cloud only.",
            kind: .toggle
        ) {
            SettingsSwitch(title: "Translate by voice", isOn: Binding(
                get: { model.voiceCommandsEnabled }, set: { model.setVoiceCommandsEnabled($0) }
            ))
            .accessibilityIdentifier("languages.voice.enabled")
        }
        SettingsLineRow(title: "Listen for the command", kind: .segmented) {
            Picker("Listen for the command", selection: Binding(
                get: { model.voicePosition }, set: { model.setVoicePosition($0) }
            )) {
                ForEach(VoiceTranslationCommandPosition.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("languages.voice.position")
        }
        .disabled(!model.voiceCommandsEnabled)
        // Decision 11 default: today's choice stays as a native pop-up (the prototype shows text only).
        SettingsLineRow(title: "Languages you can ask for", kind: .popUp, showsHairline: false) {
            Picker("Languages you can ask for", selection: Binding(
                get: { model.voiceTargets }, set: { model.setVoiceTargets($0) }
            )) {
                ForEach(VoiceTranslationCommandTargets.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("languages.voice.targets")
        }
        .disabled(!model.voiceCommandsEnabled)
    }
}

/// "Change": opens the Change popup on its floating surface, hung from the button.
private struct ChangeButton: View {
    let list: LanguageChangeList
    let model: LanguagesSettingsModel
    let presenter: FloatingSurfacePresenter
    var identifier: String?

    @State private var anchor = FloatingSurfaceAnchor()

    private var id: String {
        identifier ?? (list == .speak ? "languages.speak.change" : "languages.yours.change")
    }

    var body: some View {
        Button("Change") {
            guard let frame = anchor.screenFrame else { return }
            presenter.togglePopup(
                owner: id, name: list.popupName, anchor: frame, parent: anchor.window, fromKeyboard: false
            ) { close in
                ChangeLanguagesPopup(list: list, model: model, onClose: close)
            }
        }
        .floatingSurfaceAnchor(anchor)
        .accessibilityIdentifier(id)
    }
}
