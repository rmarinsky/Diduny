import DynamicNotchKit
import Observation
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
    case translation(languagePair: String = "EN <-> UK")
    case meeting
    case meetingTranslation

    var label: String {
        switch self {
        case .voice: "Recording..."
        case let .translation(pair): "Recording (\(pair))..."
        case .meeting: "Meeting Recording..."
        case .meetingTranslation: "Meeting Translation..."
        }
    }

    var processingLabel: String {
        switch self {
        case .voice: "Processing..."
        case .translation: "Translating..."
        case .meeting: "Processing Meeting..."
        case .meetingTranslation: "Translating Meeting..."
        }
    }

    var icon: String {
        switch self {
        case .voice: "mic.fill"
        case .translation: "globe"
        case .meeting: "laptopcomputer"
        case .meetingTranslation: "captions.bubble.fill"
        }
    }
}

@Observable
@MainActor
final class NotchManager {
    static let shared = NotchManager()

    private(set) var state: NotchState = .idle
    private(set) var recordingStartTime: Date?
    var audioLevel: Float = 0

    private var notch: DynamicNotch<NotchExpandedView, NotchCompactLeadingView, NotchCompactTrailingView>?
    private var autoDismissTask: Task<Void, Never>?

    private init() {}

    func startRecording(mode: RecordingMode = .voice) {
        autoDismissTask?.cancel()
        recordingStartTime = Date()
        state = .recording(mode: mode)
        showCompact()
    }

    func startProcessing(mode: RecordingMode = .voice) {
        autoDismissTask?.cancel()
        recordingStartTime = nil
        audioLevel = 0
        state = .processing(mode: mode)
        showCompact()
    }

    func showSuccess(text: String) {
        autoDismissTask?.cancel()
        recordingStartTime = nil
        audioLevel = 0
        state = .success(text: text)
        showExpanded()
        scheduleAutoDismiss(delay: 2.0)
    }

    func showError(message: String) {
        autoDismissTask?.cancel()
        recordingStartTime = nil
        audioLevel = 0
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
        recordingStartTime = nil
        audioLevel = 0
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

    private var screenHasNotch: Bool {
        NSScreen.main?.auxiliaryTopLeftArea != nil && NSScreen.main?.auxiliaryTopRightArea != nil
    }

    private func showCompact() {
        ensureNotch()
        if screenHasNotch {
            Task {
                await notch?.compact()
            }
        } else {
            // Floating style doesn't support compact — use expanded instead
            Task {
                await notch?.expand()
            }
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
