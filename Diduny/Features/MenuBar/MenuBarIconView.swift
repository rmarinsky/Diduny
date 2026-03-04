import SwiftUI

struct MenuBarIconView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        if let statusEmoji = statusEmoji {
            Text(statusEmoji)
        } else {
            Image("MenuBarIcon")
        }
    }

    /// Returns an emoji for active states, or nil for idle (to show robot icon)
    private var statusEmoji: String? {
        // Meeting translation takes priority
        if appState.meetingTranslationRecordingState == .recording {
            return "🌐"
        }
        if appState.meetingTranslationRecordingState == .processing {
            return "⏳"
        }

        // Meeting recording
        if appState.meetingRecordingState == .recording {
            return "🎙️"
        }
        if appState.meetingRecordingState == .processing {
            return "⏳"
        }

        // Translation recording
        switch appState.translationRecordingState {
        case .recording:
            return "🔴"
        case .processing:
            return "⏳"
        case .success:
            return "✅"
        case .error:
            return "❌"
        case .idle:
            break
        }

        // Regular recording
        switch appState.recordingState {
        case .idle:
            if appState.meetingTranslationRecordingState == .success || appState.meetingRecordingState == .success {
                return "✅"
            } else if appState.meetingTranslationRecordingState == .error || appState.meetingRecordingState == .error {
                return "❌"
            }
            return nil // Show robot icon
        case .recording:
            return "🔴"
        case .processing:
            return "⏳"
        case .success:
            return "✅"
        case .error:
            return "❌"
        }
    }
}

#Preview {
    MenuBarIconView()
        .environment(AppState())
}
