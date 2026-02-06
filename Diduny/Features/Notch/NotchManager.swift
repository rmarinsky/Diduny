import DynamicNotchKit
import SwiftUI

enum NotchState: Equatable {
    case idle
    case recording(mode: RecordingMode)
    case processing(mode: RecordingMode)
    case success(text: String)
    case error(message: String)
    case info(message: String)
}

enum RecordingMode: Equatable {
    case voice
    case translation
    case meeting

    var label: String {
        switch self {
        case .voice: "Recording..."
        case .translation: "Recording (Translate)..."
        case .meeting: "Meeting Recording..."
        }
    }

    var processingLabel: String {
        switch self {
        case .voice: "Processing..."
        case .translation: "Translating..."
        case .meeting: "Processing Meeting..."
        }
    }

    var icon: String {
        switch self {
        case .voice: "mic.fill"
        case .translation: "globe"
        case .meeting: "laptopcomputer"
        }
    }
}

@MainActor
final class NotchManager: ObservableObject {
    static let shared = NotchManager()

    @Published private(set) var state: NotchState = .idle

    private var notch: DynamicNotch<NotchExpandedView, NotchCompactLeadingView, NotchCompactTrailingView>?
    private var autoDismissTask: Task<Void, Never>?

    private init() {}

    func startRecording(mode: RecordingMode = .voice) {
        autoDismissTask?.cancel()
        state = .recording(mode: mode)
        showCompact()
    }

    func startProcessing(mode: RecordingMode = .voice) {
        autoDismissTask?.cancel()
        state = .processing(mode: mode)
        showCompact()
    }

    func showSuccess(text: String) {
        autoDismissTask?.cancel()
        state = .success(text: text)
        showExpanded()
        scheduleAutoDismiss(delay: 2.0)
    }

    func showError(message: String) {
        autoDismissTask?.cancel()
        state = .error(message: message)
        showExpanded()
        scheduleAutoDismiss(delay: 3.0)
    }

    /// Show informational message (e.g., "Press ESC again to cancel")
    func showInfo(message: String, duration: TimeInterval = 1.5) {
        autoDismissTask?.cancel()
        state = .info(message: message)
        showExpanded()
        scheduleAutoDismiss(delay: duration)
    }

    func hide() {
        autoDismissTask?.cancel()
        state = .idle
        Task {
            await notch?.hide()
        }
    }

    private func ensureNotch() {
        if notch == nil {
            notch = DynamicNotch {
                NotchExpandedView(manager: self)
            } compactLeading: {
                NotchCompactLeadingView(manager: self)
            } compactTrailing: {
                NotchCompactTrailingView(manager: self)
            }
        }
    }

    private func showCompact() {
        ensureNotch()
        Task {
            await notch?.compact()
        }
    }

    private func showExpanded() {
        ensureNotch()
        Task {
            await notch?.expand()
        }
    }

    private func scheduleAutoDismiss(delay: TimeInterval) {
        autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            hide()
        }
    }
}
