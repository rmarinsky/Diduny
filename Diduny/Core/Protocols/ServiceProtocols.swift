import AVFoundation
import CoreAudio
import Foundation

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
