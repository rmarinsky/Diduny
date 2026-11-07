import SwiftUI

/// "Whisper options" under the table (changes/04 §8a): today's keys, new labels and captions.
struct WhisperOptionsSection: View {
    var settings: SettingsStorage = .shared

    @State private var language = SettingsStorage.shared.whisperLanguage
    @State private var prompt = SettingsStorage.shared.whisperPrompt
    @State private var unloadPolicy = SettingsStorage.shared.whisperModelUnloadPolicy
    @State private var isEditingPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Whisper options")
                .font(DS.Font.groupHeading)
                .foregroundStyle(DS.Palette.text)
                .accessibilityAddTraits(.isHeader)
            SettingsLineRow(title: "Language", caption: "Used by Whisper only.", kind: .popUp) {
                // The source-language picker keeps today's 53 languages (plan 2.2, Q10).
                Picker("Language", selection: $language) {
                    ForEach(SupportedLanguage.whisperLanguages) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("models.whisper.language")
            }
            SettingsLineRow(title: "Initial prompt", caption: "Names and terms Whisper should expect.", kind: .button) {
                Button("Edit") { isEditingPrompt = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("models.whisper.prompt")
            }
            SettingsLineRow(title: "Unload the model after", caption: "Frees memory when you are not recording.",
                            kind: .popUp, showsHairline: false) {
                Picker("Unload the model after", selection: $unloadPolicy) {
                    ForEach(WhisperModelUnloadPolicy.allCases) { Text(Self.label($0)).tag($0) }
                }
                .labelsHidden()
                .accessibilityIdentifier("models.whisper.unload")
            }
        }
        .onAppear {
            language = settings.whisperLanguage
            prompt = settings.whisperPrompt
            unloadPolicy = settings.whisperModelUnloadPolicy
        }
        .onChange(of: language) { _, new in settings.whisperLanguage = new }
        .onChange(of: unloadPolicy) { _, new in settings.whisperModelUnloadPolicy = new }
        .sheet(isPresented: $isEditingPrompt) {
            WhisperPromptSheet(prompt: prompt) { new in
                prompt = new
                settings.whisperPrompt = new
            }
        }
    }

    /// Sentence case for this menu; `displayName` stays as General uses it.
    static func label(_ policy: WhisperModelUnloadPolicy) -> LocalizedStringKey {
        switch policy {
        case .seconds30: "30 seconds"
        case .minutes1: "1 minute"
        case .minutes2: "2 minutes"
        case .minutes5: "5 minutes"
        case .minutes10: "10 minutes"
        case .keepLoaded: "Keep loaded"
        }
    }
}

/// Plan 2.2 default for 04 Q8: "Edit" opens a sheet.
private struct WhisperPromptSheet: View {
    @State var prompt: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Initial prompt").font(DS.Font.headline)
            Text("Names and terms Whisper should expect.").font(DS.Font.meta).foregroundStyle(DS.Palette.secondary)
            TextEditor(text: $prompt)
                .font(DS.Font.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.field).stroke(DS.Palette.line, lineWidth: 1))
                .accessibilityIdentifier("models.whisper.promptEditor")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(prompt)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("models.whisper.promptSave")
            }
        }
        .padding(DS.Space.lg)
        .frame(width: 420)
    }
}
