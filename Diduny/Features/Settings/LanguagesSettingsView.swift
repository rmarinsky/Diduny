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
                group("Your languages", first: true)
                yourLanguagesRows
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

    /// Numbered rows in hint and menu order; drag a row onto another to reorder. The order is saved at once.
    private var yourLanguagesRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(["Shown first and in crimson in every Translate into menu and language list.",
                     "Sent to every engine as a hint, in this order. With none chosen the engine detects the language."],
                    id: \.self) { caption in
                Text(LocalizedStringKey(caption))
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            ForEach(Array(model.yourLanguages.enumerated()), id: \.element) { index, code in
                HStack(spacing: DS.Space.md) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(DS.Palette.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: "\(index + 1)")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.secondary)
                        .frame(minWidth: 14)
                    Text(verbatim: LanguagesSettingsModel.name(code))
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.text)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
                .draggable(code)
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first else { return false }
                    model.move(dragged, to: index)
                    return true
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("languages.yours.row.\(code)")
                Rectangle().fill(DS.Palette.line).frame(height: 1)
            }
            HStack {
                ChangeButton(list: .yourLanguages, model: model, presenter: presenter, title: "Add a language")
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
        }
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
    var title: LocalizedStringKey = "Change"

    @State private var anchor = FloatingSurfaceAnchor()

    private var id: String {
        identifier ?? (list == .speak ? "languages.speak.change" : "languages.yours.change")
    }

    var body: some View {
        Button(title) {
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
