import Combine
import SwiftUI

struct RecordingIndicatorView: View {
    @Environment(AppState.self) var appState
    @State private var isPulsing = false
    @State private var colonVisible = true
    @State private var currentDuration: TimeInterval = 0
    @State private var timer: AnyCancellable?

    var body: some View {
        HStack(spacing: 8) {
            // Status icon
            statusIcon
                .font(.system(size: 12))

            // Status text
            statusText
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 90, minHeight: 36)
        .background(backgroundView)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        .onAppear {
            startAnimations()
        }
        .onDisappear {
            stopTimer()
        }
        .onChange(of: appState.recordingState) { _, state in
            handleStateChange(state, isTranslation: false)
        }
        .onChange(of: appState.translationRecordingState) { _, state in
            handleStateChange(RecordingState(from: state), isTranslation: true)
        }
    }

    private func handleStateChange(_ state: RecordingState, isTranslation: Bool) {
        // Only handle if this is the active recording type
        let isActiveType = isTranslation
            ? appState.translationRecordingState != .idle
            : appState.translationRecordingState == .idle

        guard isActiveType else { return }

        if state == .recording {
            startTimer()
        } else {
            stopTimer()
        }
    }

    // MARK: - Timer Management

    private func startAnimations() {
        // Start pulsing animation for the red circle
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            isPulsing = true
        }

        // Start timer if already recording
        if activeState == .recording {
            startTimer()
        }
    }

    private func startTimer() {
        // Stop any existing timer first
        timer?.cancel()
        timer = nil

        // Reset duration and update immediately
        currentDuration = 0
        updateDuration()

        // Create a timer that fires every 0.5 seconds for smooth colon blinking
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                colonVisible.toggle()
                updateDuration()
            }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        colonVisible = true
    }

    private func updateDuration() {
        currentDuration = activeDuration
    }

    // MARK: - Status Views

    @ViewBuilder
    private var statusIcon: some View {
        switch activeState {
        case .recording:
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .scaleEffect(isPulsing ? 1.2 : 1.0)

        case .processing:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 10, height: 10)

        case .success:
            Image(systemName: "checkmark")
                .foregroundColor(.green)

        case .error:
            Image(systemName: "xmark")
                .foregroundColor(.red)

        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch activeState {
        case .recording:
            timerText

        case .processing:
            Text("")

        case .success:
            Text("Copied")

        case .error:
            if appState.isEmptyTranscription {
                Text("I hear nothing")
            } else {
                Text("Error")
            }

        case .idle:
            EmptyView()
        }
    }

    private var timerText: some View {
        let duration = Int(currentDuration)
        let minutes = duration / 60
        let seconds = duration % 60

        return HStack(spacing: 0) {
            Text(String(format: "%02d", minutes))
            Text(":")
                .opacity(colonVisible ? 1.0 : 0.0)
            Text(String(format: "%02d", seconds))
        }
    }

    // MARK: - State Helpers

    /// Returns the active recording state (translation takes priority if not idle)
    private var activeState: RecordingState {
        // Translation recording state (if not idle, it takes priority)
        switch appState.translationRecordingState {
        case .recording: return .recording
        case .processing: return .processing
        case .success: return .success
        case .error: return .error
        case .idle: break
        }
        // Fall back to regular recording state
        return appState.recordingState
    }

    /// Returns the active recording duration
    private var activeDuration: TimeInterval {
        if appState.translationRecordingState != .idle {
            return appState.translationRecordingDuration
        }
        return appState.recordingDuration
    }

    private var backgroundView: some View {
        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
    }
}

// MARK: - Visual Effect Blur for macOS

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

#Preview {
    RecordingIndicatorView()
        .environment(AppState())
        .frame(width: 150, height: 40)
}
