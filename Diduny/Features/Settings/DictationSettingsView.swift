import SwiftUI

struct DictationSettingsView: View {
    @State private var transcriptionProvider: TranscriptionProvider = SettingsStorage.shared.transcriptionProvider

    var body: some View {
        Form {
            Section("Transcription Provider") {
                Picker("Provider", selection: $transcriptionProvider) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: transcriptionProvider) { _, newValue in
                    SettingsStorage.shared.transcriptionProvider = newValue
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    DictationSettingsView()
        .frame(width: 500, height: 650)
}
