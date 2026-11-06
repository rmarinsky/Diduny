import SwiftUI

/// The ElevenLabs key popup (design-spec 4.9 key variant, 7.9; 03 3.2 B): four Settings rows and the foot.
struct ElevenLabsKeyPopup: View {
    @Bindable var state: KeyPopupState
    let close: () -> Void
    let openDashboard: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        PopupShell(
            icon: "key", title: "ElevenLabs", subtitle: String(localized: "Key saved"), bodyStyle: .plain,
            accessibilityTitle: String(localized: "ElevenLabs key"), onClose: close
        ) {
            VStack(alignment: .leading, spacing: 0) {
                keyRow
                connectionRow
                SettingsLineRow(title: "Used this month", kind: .button) {
                    Text(verbatim: state.usage.text())
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.secondary)
                        .accessibilityIdentifier("key.usage")
                    Button("ElevenLabs dashboard", action: openDashboard)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("key.dashboard")
                }
                SettingsLineRow(
                    title: "Remove the key", caption: "Modes that use ElevenLabs go back to Diduny Cloud.",
                    kind: .button, showsHairline: false
                ) {
                    if state.removeArmed {
                        Button("Remove the key", role: .destructive) {
                            state.confirmRemove()
                            close()
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(DS.Palette.no)
                        .accessibilityIdentifier("key.remove")
                        Button("Keep") { state.keep() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("key.keep")
                    } else {
                        Button("Remove", role: .destructive) { state.armRemove() }
                            .buttonStyle(.bordered)
                            .foregroundStyle(DS.Palette.no)
                            .accessibilityIdentifier("key.remove")
                    }
                }
            }
        } footer: {
            Text("ElevenLabs transcribes with your key and bills you. Audio and the key are not sent to Diduny. Translation is done by Diduny on the text.")
        }
        .task { await state.refresh() }
        .onDisappear { state.popupClosed() }
    }

    @ViewBuilder private var keyRow: some View {
        if state.isReplacing {
            SettingsLineRow(title: "Key", caption: state.replaceFailed ? "Couldn't save the key to Keychain." : nil, kind: .button) {
                SecureField("ElevenLabs API key", text: $state.replacement, prompt: Text("Paste your ElevenLabs API key"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .focused($fieldFocused)
                    .onSubmit { Task { await state.saveReplacement() } }
                    .onKeyPress(.escape) {
                        state.cancelReplace()
                        return .handled
                    }
                    .accessibilityIdentifier("key.field")
                Button("Save") { Task { await state.saveReplacement() } }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Palette.accentFill)
                    .disabled(!state.canSaveReplacement)
                    .accessibilityIdentifier("key.save")
                Button("Cancel") { state.cancelReplace() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("key.cancel")
            }
            .onAppear { fieldFocused = true }
        } else {
            SettingsLineRow(title: "Key", kind: .button) {
                Text(verbatim: state.maskedKey ?? "")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
                    .accessibilityIdentifier("key.masked")
                Button("Replace") { state.beginReplace() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("key.replace")
            }
        }
    }

    private var connectionRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsLineRow(title: "Connection", kind: .button) {
                Text(verbatim: state.connection.text)
                    .font(DS.Font.meta)
                    .foregroundStyle(connectionColor)
                    .accessibilityIdentifier("key.connection")
                Button("Test") { Task { await state.test() } }
                    .buttonStyle(.bordered)
                    .disabled(state.connection == .testing)
                    .accessibilityIdentifier("key.test")
            }
            if let detail = state.connection.detail {
                Text(verbatim: detail)
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, DS.Space.xs)
            }
        }
    }

    private var connectionColor: Color {
        switch state.connection {
        case .failed(.invalidKey): DS.Palette.no
        case .failed: DS.Palette.warn
        default: DS.Palette.secondary
        }
    }
}
