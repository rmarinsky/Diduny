import SwiftUI

/// Settings > Local models (design-spec 7.10, changes/04): one table for Parakeet V3, Apple Speech and
/// the 12 Whisper models, then the Whisper options.
struct OfflineModelsSettingsView: View {
    @State private var model = LocalModelsModel(
        whisper: WhisperModelManagerStore(),
        parakeet: ParakeetModelController.shared,
        isAppleSpeechAvailable: AppleBenchmarkEngine().availability() == .ready,
        yourLanguages: SettingsStorage.shared.yourLanguages
    )

    var body: some View {
        PageScaffold(title: "Local models", subtitle: "Run on this Mac. Audio never leaves it.") {
            VStack(alignment: .leading, spacing: 18) {
                ModelTable(model: model)
                WhisperOptionsSection()
            }
        }
        .onAppear { ParakeetModelController.shared.refresh() }
        // Escape and leaving the page count as Keep (design-spec 4.12).
        .onExitCommand { model.keep() }
        .onDisappear { model.keep() }
    }
}

#Preview {
    OfflineModelsSettingsView()
        .frame(width: 762, height: 680)
}
