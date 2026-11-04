import AVFoundation
import FluidAudio
import Foundation
import Speech

enum BenchmarkEngineKind: String, Codable {
    case cloud, local, onDevice
}

enum BenchmarkAvailability: Equatable {
    case ready
    case notDownloaded
    case noKey
    case signedOut
    case appleSiliconOnly
    case notOnThisMac
}

struct BenchmarkOutput: Sendable {
    let text: String
    let seconds: TimeInterval
    /// Model load time, reported apart from transcription time (0 when warm or remote).
    let loadSeconds: TimeInterval
}

/// One engine the Benchmark tab can run on a recording's audio file.
protocol BenchmarkEngine: Sendable {
    var id: String { get }
    var name: String { get }
    var kind: BenchmarkEngineKind { get }
    /// Matches a provider selection when this engine can be made the dictation default.
    var defaultSelection: JobProviderSelection? { get }
    @MainActor func availability() -> BenchmarkAvailability
    func transcribe(_ url: URL, language: String) async throws -> BenchmarkOutput
}

private func timed<T>(_ body: () async throws -> T) async rethrows -> (T, TimeInterval) {
    let start = Date()
    let value = try await body()
    return (value, Date().timeIntervalSince(start))
}

// MARK: - Diduny (cloud)

struct DidunyBenchmarkEngine: BenchmarkEngine {
    let id = "diduny"
    let name = "Diduny"
    let kind = BenchmarkEngineKind.cloud
    var defaultSelection: JobProviderSelection? { .didunyCloud }

    @MainActor func availability() -> BenchmarkAvailability {
        AuthService.shared.isLoggedIn ? .ready : .signedOut
    }

    func transcribe(_ url: URL, language: String) async throws -> BenchmarkOutput {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let (result, seconds) = try await timed { try await CloudTranscriptionService().transcribeRawAndCleaned(audioData: data, language: language) }
        return BenchmarkOutput(text: result.raw, seconds: seconds, loadSeconds: 0)
    }
}

// MARK: - ElevenLabs (bring your own key)

struct ElevenLabsBenchmarkEngine: BenchmarkEngine {
    let id = "elevenlabs"
    let name = "ElevenLabs Scribe"
    let kind = BenchmarkEngineKind.cloud
    var defaultSelection: JobProviderSelection? { JobProviderSelection(providerID: STTProviderID.elevenLabs, modelID: nil) }

    @MainActor func availability() -> BenchmarkAvailability {
        ProviderKeyStore.shared.key(for: STTProviderID.elevenLabs) == nil ? .noKey : .ready
    }

    func transcribe(_ url: URL, language: String) async throws -> BenchmarkOutput {
        let (result, seconds) = try await timed { try await ElevenLabsBatchService().transcribe(audioURL: url, languageCode: language) }
        return BenchmarkOutput(text: result.transcript.text, seconds: seconds, loadSeconds: 0)
    }
}

// MARK: - Whisper (local, one engine per downloaded model)

struct WhisperBenchmarkEngine: BenchmarkEngine {
    let model: WhisperModelManager.WhisperModel
    var id: String { "whisper-\(model.name)" }
    var name: String { "Whisper \(model.displayName)" }
    let kind = BenchmarkEngineKind.local
    var defaultSelection: JobProviderSelection? {
        SettingsStorage.shared.selectedWhisperModel == model.name
            ? JobProviderSelection(providerID: STTProviderID.localWhisper, modelID: nil) : nil
    }

    @MainActor func availability() -> BenchmarkAvailability {
        WhisperModelManager.shared.isModelDownloaded(model) ? .ready : .notDownloaded
    }

    func transcribe(_ url: URL, language: String) async throws -> BenchmarkOutput {
        let samples = try AudioConverter.convertToWhisperFormat(audioData: Data(contentsOf: url, options: .mappedIfSafe))
        let path = WhisperModelManager.shared.modelPath(for: model)
        let (context, load) = try await timed { try WhisperContext(modelPath: path) }
        let (transcript, seconds) = try await timed { try await context.transcribe(samples: samples, language: language) }
        return BenchmarkOutput(text: transcript.text.trimmingCharacters(in: .whitespacesAndNewlines), seconds: seconds, loadSeconds: load)
    }
}

// MARK: - Parakeet V3 (local, Neural Engine via FluidAudio)

actor ParakeetModelStore {
    static let shared = ParakeetModelStore()
    static var isSupportedHardware: Bool {
        #if arch(arm64)
            true
        #else
            false
        #endif
    }

    static var directory: URL { AsrModels.defaultCacheDirectory(for: .v3) }
    static var isDownloaded: Bool { AsrModels.modelsExist(at: directory, version: .v3) }

    private var manager: AsrManager?

    /// Loads (downloading on first use) and returns the manager plus the time it took.
    func loaded(progress: ((Double) -> Void)? = nil) async throws -> (AsrManager, TimeInterval) {
        if let manager { return (manager, 0) }
        let start = Date()
        let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: progress.map { handler in
            { handler($0.fractionCompleted) }
        })
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        return (manager, Date().timeIntervalSince(start))
    }

    func delete() throws {
        manager = nil
        try FileManager.default.removeItem(at: Self.directory)
    }
}

struct ParakeetBenchmarkEngine: BenchmarkEngine {
    let id = "parakeet-v3"
    let name = "Parakeet V3"
    let kind = BenchmarkEngineKind.local
    let defaultSelection: JobProviderSelection? = nil

    @MainActor func availability() -> BenchmarkAvailability {
        guard ParakeetModelStore.isSupportedHardware else { return .appleSiliconOnly }
        return ParakeetModelStore.isDownloaded ? .ready : .notDownloaded
    }

    func transcribe(_ url: URL, language: String) async throws -> BenchmarkOutput {
        let samples = try AudioConverter.convertToWhisperFormat(audioData: Data(contentsOf: url, options: .mappedIfSafe))
        let (manager, load) = try await ParakeetModelStore.shared.loaded()
        let hint = Language(rawValue: language)
        var state = TdtDecoderState.make()
        let (result, seconds) = try await timed { try await manager.transcribe(samples, decoderState: &state, language: hint) }
        return BenchmarkOutput(text: result.text, seconds: seconds, loadSeconds: load)
    }
}

// MARK: - Apple (on-device)

struct AppleBenchmarkEngine: BenchmarkEngine {
    let id = "apple"
    let name = "Apple"
    let kind = BenchmarkEngineKind.onDevice
    let defaultSelection: JobProviderSelection? = nil

    @MainActor func availability() -> BenchmarkAvailability {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: BenchmarkRunner.defaultLanguage)), recognizer.supportsOnDeviceRecognition else {
            return .notOnThisMac
        }
        return .ready
    }

    func transcribe(_ url: URL, language: String) async throws -> BenchmarkOutput {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { cont in SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) } }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
        else { throw TranscriptionError.emptyTranscription }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        let (text, seconds) = try await timed {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                var done = false
                recognizer.recognitionTask(with: request) { result, error in
                    guard !done else { return }
                    if let result, result.isFinal {
                        done = true
                        cont.resume(returning: result.bestTranscription.formattedString)
                    } else if let error {
                        done = true
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        return BenchmarkOutput(text: text, seconds: seconds, loadSeconds: 0)
    }
}

enum BenchmarkEngineCatalog {
    /// Every engine, ready or not. Parakeet is omitted on Intel (spec AC).
    static func all() -> [any BenchmarkEngine] {
        var engines: [any BenchmarkEngine] = [DidunyBenchmarkEngine(), ElevenLabsBenchmarkEngine()]
        if ParakeetModelStore.isSupportedHardware { engines.append(ParakeetBenchmarkEngine()) }
        engines += WhisperModelManager.availableModels.map { WhisperBenchmarkEngine(model: $0) }
        engines.append(AppleBenchmarkEngine())
        return engines
    }
}
