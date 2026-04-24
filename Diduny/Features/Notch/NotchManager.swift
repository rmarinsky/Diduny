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
        recordingStartTime = Date()
        resumeRecording(mode: mode)
    }

    func resumeRecording(mode: RecordingMode = .voice) {
        autoDismissTask?.cancel()
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

    func showInfo(message: String, duration: TimeInterval = 1.5) {
        autoDismissTask?.cancel()
        state = .info(message: message)
        showExpanded()
        scheduleAutoDismiss(delay: duration)
    }

    /// Show info message during active recording, then auto-restore recording UI with preserved timer.
    func showInfoDuringRecording(message: String, mode: RecordingMode, duration: TimeInterval = 1.5) {
        autoDismissTask?.cancel()
        let savedStartTime = recordingStartTime
        state = .info(message: message)
        showExpanded()
        autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            recordingStartTime = savedStartTime
            state = .recording(mode: mode)
            showCompact()
        }
    }

    func hide() {
        autoDismissTask?.cancel()
        recordingStartTime = nil
        audioLevel = 0
        state = .idle
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
