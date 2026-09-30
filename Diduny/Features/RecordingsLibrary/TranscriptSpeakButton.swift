import SwiftUI

/// Speaker button that synthesizes and plays a transcript (or translation)
/// via 60db text-to-speech. Used in transcript cards, list rows, and menus.
struct TranscriptSpeakButton: View {
    let versionId: UUID
    let text: String
    var languageCode: String?
    /// Icon-only circle style matching `RecordingActionButton` (for list rows).
    var compact = false

    @State private var ttsService = SixtyDBTTSService.shared
    @State private var errorMessage: String?

    private var isActive: Bool {
        ttsService.speakingVersionId == versionId
    }

    var body: some View {
        buttonBody
            .controlSize(.small)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(isActive ? "Stop speaking" : "Read aloud with text-to-speech")
            .accessibilityLabel(isActive ? "Stop speaking" : "Read aloud with text-to-speech")
            .alert(
                "Speech Failed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var buttonBody: some View {
        if compact {
            button.buttonStyle(.plain)
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            speak()
        } label: {
            if compact {
                if isActive, ttsService.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 28, height: 28)
                        .background(Color(.quaternaryLabelColor).opacity(0.10), in: Circle())
                } else {
                    Image(systemName: isActive && ttsService.isSpeaking ? "stop.fill" : "speaker.wave.2")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color("BrandAccentDeep"))
                        .frame(width: 28, height: 28)
                        .background(Color(.quaternaryLabelColor).opacity(0.10), in: Circle())
                }
            } else {
                HStack(spacing: 4) {
                    if isActive, ttsService.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: isActive && ttsService.isSpeaking ? "stop.fill" : "speaker.wave.2")
                    }
                    Text(isActive ? "Stop" : "Speak")
                }
            }
        }
    }

    private func speak() {
        Task {
            do {
                try await ttsService.toggleSpeak(
                    versionId: versionId,
                    text: text,
                    languageCode: languageCode
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
