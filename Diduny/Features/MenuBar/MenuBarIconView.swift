import SwiftUI

struct MenuBarIconView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        if let statusEmoji = statusEmoji {
            Text(statusEmoji)
        } else {
            HStack(spacing: 2) {
                Image("MenuBarIcon")
                if appState.ambientListeningActive {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                }
            }
        }
    }

    /// Returns an emoji for active states, or nil for idle (to show robot icon)
    private var statusEmoji: String? {
        // Meeting recording takes priority
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
            if appState.meetingRecordingState == .success {
                return "✅"
            } else if appState.meetingRecordingState == .error {
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
