import AppKit
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
    case fileTranscription

    var label: String {
        switch self {
        case .voice: "Recording..."
        case let .translation(pair): "Recording (\(pair))..."
        case .meeting: "Meeting Recording..."
        case .meetingTranslation: "Meeting Translation..."
        case .fileTranscription: "Transcribing File..."
        }
    }

    var processingLabel: String {
        switch self {
        case .voice: "Processing..."
        case .translation: "Translating..."
        case .meeting: "Processing Meeting..."
        case .meetingTranslation: "Translating Meeting..."
        case .fileTranscription: "Transcribing File..."
        }
    }

    var icon: String {
        switch self {
        case .voice: "mic.fill"
        case .translation: "globe"
        case .meeting: "laptopcomputer"
        case .meetingTranslation: "captions.bubble.fill"
        case .fileTranscription: "doc.richtext.fill"
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
    private var onStopRequested: (@MainActor () async -> Void)?
    private var operationSequence: UInt64 = 0

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
        updatePanelMouseEvents()
        operationSequence &+= 1
        let seq = operationSequence
        Task {
            guard self.operationSequence == seq else { return }
            await notch?.hide()
        }
    }

    func setStopHandler(_ handler: (@MainActor () async -> Void)?) {
        onStopRequested = handler
    }

    func requestStopActiveRecording() {
        guard case .recording = state else { return }
        guard let onStopRequested else { return }
        Task { @MainActor in
            await onStopRequested()
        }
    }

    var isStopControlVisible: Bool {
        if case .recording = state {
            return true
        }
        return false
    }

    /// Keep the panel non-interactive by default so it never blocks the upper screen.
    /// Recording mode opts into hit testing for the explicit Stop control only.
    private func updatePanelMouseEvents() {
        guard let panel = notch?.windowController?.window else { return }
        panel.ignoresMouseEvents = !isStopControlVisible
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

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return mouseScreen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    private func screenHasNotch(_ screen: NSScreen) -> Bool {
        screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }

    private func showCompact() {
        ensureNotch()
        guard let screen = activeScreen() else { return }

        operationSequence &+= 1
        let seq = operationSequence
        Task {
            guard self.operationSequence == seq else { return }
            if screenHasNotch(screen) {
                await notch?.compact(on: screen)
            } else {
                await notch?.expand(on: screen)
            }
            updatePanelMouseEvents()
        }
    }

    private func showExpanded() {
        ensureNotch()
        guard let screen = activeScreen() else { return }
        operationSequence &+= 1
        let seq = operationSequence
        Task {
            guard self.operationSequence == seq else { return }
            await notch?.expand(on: screen)
            updatePanelMouseEvents()
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
