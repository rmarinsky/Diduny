import Foundation
import Observation
import os

enum RecordingState: Equatable, CustomStringConvertible {
    case idle
    case recording
    case processing
    case success
    case error

    var description: String {
        switch self {
        case .idle: "idle"
        case .recording: "recording"
        case .processing: "processing"
        case .success: "success"
        case .error: "error"
        }
    }
}

@Observable
@MainActor
final class AppState {
    var billingSelection: BillingSelection?
    /// The command panel's pick for the recording a tile started, by job. Set at the tile start and dropped
    /// when that recording ends, so hotkey starts keep following Settings > Modes.
    var panelEngines: [STTJob: JobProviderSelection] = [:]

    /// After a tile start returns: a refused start never left idle, and a later hotkey start must not inherit the pick.
    func dropPanelEngineIfIdle(_ job: STTJob) {
        let state: RecordingState = switch job {
        case .dictation: recordingState
        case .dictationTranslation: translationRecordingState
        case .meetingTranslation: meetingTranslationRecordingState
        default: .recording
        }
        if state == .idle { panelEngines[job] = nil }
    }

    var recordingState: RecordingState = .idle {
        didSet {
            if recordingState == .idle { panelEngines[.dictation] = nil }
            Log.app.debug("recordingState changed: \(oldValue.description) -> \(self.recordingState.description)")
        }
    }

    var recordingStartTime: Date?
    var lastTranscription: String?
    var errorMessage: String? {
        didSet {
            if let msg = errorMessage {
                Log.app.debug("errorMessage set: \(msg)")
            }
        }
    }

    var isEmptyTranscription: Bool = false

    /// Warning message shown when selected device is unavailable and fallback was used
    var deviceFallbackWarning: String? {
        didSet {
            if let warning = deviceFallbackWarning {
                Log.app.debug("deviceFallbackWarning set: \(warning)")
            }
        }
    }

    /// Preferred device UID — `nil` means "follow System Default".
    var preferredDeviceUID: String? {
        didSet {
            SettingsStorage.shared.preferredDeviceUID = preferredDeviceUID
        }
    }

    var microphonePermissionGranted: Bool = false
    var screenCapturePermissionGranted: Bool = false

    // Settings trigger (for opening settings from non-SwiftUI code)
    var shouldOpenSettings: Bool = false

    // Meeting recording
    var meetingRecordingState: RecordingState = .idle {
        didSet {
            Log.app
                .debug("meetingRecordingState changed: \(oldValue.description) -> \(self.meetingRecordingState.description)")
        }
    }

    var meetingRecordingStartTime: Date?
    var meetingChapters: [MeetingChapter] = []
    var liveTranscriptStore: LiveTranscriptStore?

    // Meeting translation (system audio -> Ukrainian)
    var meetingTranslationRecordingState: RecordingState = .idle {
        didSet {
            if meetingTranslationRecordingState == .idle { panelEngines[.meetingTranslation] = nil }
            Log.app.debug(
                "meetingTranslationRecordingState changed: \(oldValue.description) -> \(self.meetingTranslationRecordingState.description)"
            )
        }
    }

    var meetingTranslationRecordingStartTime: Date?

    // Translation recording (EN <-> UK)
    var translationRecordingState: RecordingState = .idle {
        didSet {
            if translationRecordingState == .idle { panelEngines[.dictationTranslation] = nil }
            Log.app
                .debug(
                    "translationRecordingState changed: \(oldValue.description) -> \(self.translationRecordingState.description)"
                )
        }
    }

    var translationRecordingStartTime: Date?

    init() {
        #if DEBUG || TEST_BUILD
            UITestLaunchState.applyIfRequested()
        #endif
        let settings = SettingsStorage.shared
        preferredDeviceUID = settings.preferredDeviceUID
        Log.app
            .debug(
                "Initialized: preferredDeviceUID=\(String(describing: self.preferredDeviceUID))"
            )
    }
}
