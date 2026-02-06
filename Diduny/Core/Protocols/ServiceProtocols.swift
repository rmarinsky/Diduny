import AVFoundation
import CoreAudio
import Foundation

// MARK: - Audio Recording Protocol

@MainActor
protocol AudioRecorderProtocol: AnyObject {
    var isRecording: Bool { get }
    var audioLevel: Float { get }
    var currentRecordingPath: String? { get }
    func startRecording(device: AudioDevice?) async throws
    func stopRecording() async throws -> Data
    func cancelRecording()
}

// MARK: - Transcription Service Protocol

protocol TranscriptionServiceProtocol {
    var apiKey: String? { get set }
    func transcribe(audioData: Data) async throws -> String
    func translateAndTranscribe(audioData: Data) async throws -> String
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
    func registerTranslationHotkey(handler: @escaping () -> Void)
    func unregisterRecordingHotkey()
    func unregisterMeetingHotkey()
    func unregisterTranslationHotkey()
    func unregisterAll()
}

// MARK: - Audio Device Manager Protocol

protocol AudioDeviceManagerProtocol: AnyObject {
    var availableDevices: [AudioDevice] { get }
    var defaultDevice: AudioDevice? { get }
    func refreshDevices()
    func autoDetectBestDevice() async -> AudioDevice?
    func isDeviceAvailable(_ deviceID: AudioDeviceID) -> Bool
    func device(for deviceID: AudioDeviceID) -> AudioDevice?
    func getCurrentDefaultDevice() -> AudioDevice?
}

// MARK: - Push To Talk Service Protocol

protocol PushToTalkServiceProtocol: AnyObject {
    var selectedKey: PushToTalkKey { get set }
    var onKeyDown: (() -> Void)? { get set }
    var onKeyUp: (() -> Void)? { get set }
    func start()
    func stop()
}

// MARK: - Meeting Recorder Service Protocol

@available(macOS 13.0, *)
protocol MeetingRecorderServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    var currentRecordingPath: String? { get }
    var audioSource: MeetingAudioSource { get set }
    var recordingDuration: TimeInterval { get }
    func startRecording() async throws
    func stopRecording() async throws -> URL?
    func cancelRecording()
}
