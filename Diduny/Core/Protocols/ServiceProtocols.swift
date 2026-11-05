import AVFoundation
import CoreAudio
import Foundation

// MARK: - Audio Recording Protocol

@MainActor
protocol AudioRecorderProtocol: AnyObject {
    var isRecording: Bool { get }
    var audioLevel: Float { get }
    var currentRecordingPath: String? { get }
    var currentRecordingDeviceInfo: RecordingDeviceInfo? { get }
    func startRecording(device: AudioDevice?) async throws
    func stopRecording() async throws -> Data
    func cancelRecording()
}

// MARK: - Transcription Service Protocol

protocol TranscriptionServiceProtocol {
    func transcribe(audioData: Data) async throws -> String
    func transcribeDetailed(audioData: Data) async throws -> GeneratedTranscript
    func translateAndTranscribe(audioData: Data) async throws -> String
    func translateAndTranscribe(audioData: Data, targetLanguage: String) async throws -> String
    func translateAndTranscribe(audioData: Data, languagePair: TranslationLanguagePair) async throws -> String
}

extension TranscriptionServiceProtocol {
    func transcribeDetailed(audioData: Data) async throws -> GeneratedTranscript {
        try await GeneratedTranscript(text: transcribe(audioData: audioData))
    }
}

// MARK: - Realtime Transcription Protocol

/// Streaming speech-to-text session. Diduny Cloud (`CloudRealtimeService`) is the
/// first conformer; bring-your-own-key providers plug in here.
protocol RealtimeTranscriptionProtocol: AnyObject, Sendable {
    var onTokensReceived: (([RealtimeToken]) -> Void)? { get set }
    var onSegmentBoundary: ((RealtimeSegmentBoundary) -> Void)? { get set }
    func setConnectionHandlers(
        onError: ((Error) -> Void)?,
        onConnectionStatusChanged: ((RealtimeConnectionStatus) -> Void)?
    )
    func connect(
        languageHints: [String],
        strictLanguageHints: Bool,
        audioConfig: RealtimeAudioConfig,
        translationConfig: RealtimeTranslationConfig?,
        enableSpeakerDiarization: Bool
    ) async throws
    func sendAudioData(_ data: Data)
    func finalize(profile: RealtimeFinalizeProfile) async -> RealtimeFinalizeResult
    func disconnect() async
    func clearCallbacks()
}

extension RealtimeTranscriptionProtocol {
    func connect(
        languageHints: [String] = [],
        strictLanguageHints: Bool = false,
        audioConfig: RealtimeAudioConfig = .defaultPCM16kMono,
        translationConfig: RealtimeTranslationConfig? = nil,
        enableSpeakerDiarization: Bool = true
    ) async throws {
        try await connect(
            languageHints: languageHints,
            strictLanguageHints: strictLanguageHints,
            audioConfig: audioConfig,
            translationConfig: translationConfig,
            enableSpeakerDiarization: enableSpeakerDiarization
        )
    }
}

// MARK: - Text Translation Protocol

/// Text-only translation step (no audio, no provider key). Used after a BYOK transcript
/// when the model cannot translate natively.
protocol TextTranslationProtocol: Sendable {
    func translate(text: String, sourceLanguage: String, targetLanguage: String) async throws -> String
}

// MARK: - Clipboard Service Protocol

protocol ClipboardServiceProtocol {
    func copy(text: String)
    func paste() async throws
}

// MARK: - Hotkey Service Protocol

protocol HotkeyServiceProtocol {
    func registerRecordingHotkey(handler: @escaping () -> Void)
    func registerMeetingHotkey(handler: @escaping () -> Void)
    func registerMeetingTranslationHotkey(handler: @escaping () -> Void)
    func registerTranslationHotkey(handler: @escaping () -> Void)
    func registerHistoryPaletteHotkey(handler: @escaping () -> Void)
    func unregisterRecordingHotkey()
    func unregisterMeetingHotkey()
    func unregisterMeetingTranslationHotkey()
    func unregisterTranslationHotkey()
    func unregisterHistoryPaletteHotkey()
    func registerChapterHotkey(handler: @escaping () -> Void)
    func unregisterChapterHotkey()
    func registerTranslateSelectedTextHotkey(handler: @escaping () -> Void)
    func unregisterTranslateSelectedTextHotkey()
    func unregisterAll()
}

// MARK: - Audio Device Manager Protocol

protocol AudioDeviceManagerProtocol: AnyObject {
    var availableDevices: [AudioDevice] { get }
    var defaultDevice: AudioDevice? { get }
    func refreshDevices()
    func isDeviceAvailable(uid: String) -> Bool
    func device(forUID uid: String) -> AudioDevice?
    func bestDevice() -> AudioDevice?
    func score(for device: AudioDevice, strategy: MicrophoneSelectionStrategy) -> AudioDeviceScore
    func recommendedDevice(strategy: MicrophoneSelectionStrategy) -> AudioDevice?
    func resolveDevice(preferredUID: String?) -> (device: AudioDevice?, didFallback: Bool)
    func resolveDevice(preferredUID: String?, strategy: MicrophoneSelectionStrategy)
        -> (device: AudioDevice?, didFallback: Bool)
}

// MARK: - Push To Talk Service Protocol

protocol PushToTalkServiceProtocol: AnyObject {
    var selectedKey: PushToTalkKey { get set }
    var holdModeEnabled: Bool { get set }
    var toggleModeEnabled: Bool { get set }
    var toggleTapCount: Int { get set }
    var holdStartDelaySeconds: TimeInterval { get set }
    var onKeyDown: (() -> Void)? { get set }
    var onKeyUp: (() -> Void)? { get set }
    /// Called when recording should toggle (for hands-free mode)
    var onToggle: (() -> Void)? { get set }
    func start()
    func stop()
    /// Reset hands-free mode (call when recording is cancelled externally)
    func resetHandsFreeMode()
}

// MARK: - Meeting Recorder Service Protocol

protocol MeetingRecorderServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    var currentRecordingPath: String? { get }
    var audioSource: MeetingAudioSource { get set }
    var recordingDuration: TimeInterval { get }
    func startRecording() async throws
    func stopRecording() async throws -> URL?
    func cancelRecording() async
}
