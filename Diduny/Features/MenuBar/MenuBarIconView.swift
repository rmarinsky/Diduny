import SwiftUI

struct MenuBarIconView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 14, weight: .regular))
    }

    private var iconName: String {
        // Meeting translation takes priority
        if appState.meetingTranslationRecordingState == .recording { return "globe" }
        if appState.meetingTranslationRecordingState == .processing { return "waveform" }

        // Meeting recording
        if appState.meetingRecordingState == .recording { return "laptopcomputer.and.arrow.down" }
        if appState.meetingRecordingState == .processing { return "waveform" }

        // Translation recording
        switch appState.translationRecordingState {
        case .recording: return "character.bubble.fill"
        case .processing: return "waveform"
        case .success: return "checkmark"
        case .error: return "xmark"
        case .idle: break
        }

        // Regular recording
        switch appState.recordingState {
        case .idle:
            if appState.meetingTranslationRecordingState == .success || appState.meetingRecordingState == .success {
                return "checkmark"
            } else if appState.meetingTranslationRecordingState == .error || appState.meetingRecordingState == .error {
                return "xmark"
            }
            return "mic"
        case .recording: return "waveform.badge.mic"
        case .processing: return "waveform"
        case .success: return "checkmark"
        case .error: return "xmark"
        }
    }
}

#Preview {
    MenuBarIconView()
        .environment(AppState())
}
