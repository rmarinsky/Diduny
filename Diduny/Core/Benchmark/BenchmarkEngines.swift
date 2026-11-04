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
    /// Language the engine heard, when it reports one (Diduny does, per token).
    var detectedLanguage: String? = nil
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

    /// Replays the clip over the realtime socket exactly like live dictation:
    /// 100ms PCM chunks at real-time pace, then Stop. `seconds` is Stop → final
    /// text, the wait the user feels; the text is raw tokens before server cleanup.
    func transcribe(_ url: URL, language: String) async throws -> BenchmarkOutput {
        let samples = try AudioConverter.convertToWhisperFormat(audioData: Data(contentsOf: url, options: .mappedIfSafe))
        let service = CloudRealtimeService()
        let collector = TokenCollector()
        service.onTokensReceived = { collector.add($0) }
        try await service.connect(languageHints: language == BenchmarkRun.autoLanguage ? [] : [language], enableSpeakerDiarization: false)
        let chunk = 1600 // 100ms at 16kHz
        var index = 0
        let clock = ContinuousClock()
        let start = clock.now
        while index < samples.count {
            try Task.checkCancellation()
            // Real-time pacing against the clock, so the tail is still in flight at Stop like live dictation.
            try await clock.sleep(until: start + .milliseconds(100 * (index / chunk)))
            let end = min(index + chunk, samples.count)
            service.sendAudioData(Self.pcm16(samples[index ..< end]))
            index = end
        }
        let (_, seconds) = await timedAsync { await service.finalize(profile: .dictationFast) }
        let text = collector.text
        await service.disconnect()
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscription }
        return BenchmarkOutput(text: text, seconds: seconds, loadSeconds: 0, detectedLanguage: collector.language)
    }

    /// Tokens arrive on the socket's queue; keep them in order without hopping tasks.
    private final class TokenCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var final = "", provisional = ""
        private var languageCounts: [String: Int] = [:]
        func add(_ tokens: [RealtimeToken]) {
            lock.lock(); defer { lock.unlock() }
            var latest = ""
            for token in tokens where !token.text.isEmpty {
                if token.isFinal {
                    final += token.text
                    if let language = token.language { languageCounts[language, default: 0] += token.text.count }
                } else { latest += token.text }
            }
            provisional = latest
        }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return (final + provisional).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// The language most of the final text was in.
        var language: String? {
            lock.lock(); defer { lock.unlock() }
            return languageCounts.max { $0.value < $1.value }?.key
        }
    }

    private static func pcm16(_ samples: ArraySlice<Float>) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func timedAsync<T>(_ work: () async -> T) async -> (T, TimeInterval) {
        let start = Date()
        let value = await work()
        return (value, Date().timeIntervalSince(start))
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

    /// macOS 26+: SpeechAnalyzer's DictationTranscriber (its newer SpeechTranscriber has no Ukrainian).
    /// Older macOS: on-device SFSpeechRecognizer.
    func transcribe(_ url: URL, language: String) async throws -> BenchmarkOutput {
        // Apple can't detect the language; in Auto it gets what Diduny heard (see the runner).
        let locale = Locale(identifier: language == BenchmarkRun.autoLanguage ? BenchmarkRunner.defaultLanguage : language)
        if #available(macOS 26, *) {
            let (text, seconds) = try await timed { try await Self.transcribeWithAnalyzer(url, locale: locale) }
            return BenchmarkOutput(text: text, seconds: seconds, loadSeconds: 0)
        }
        let (text, seconds) = try await timed { try await Self.transcribeWithRecognizer(url, locale: locale) }
        return BenchmarkOutput(text: text, seconds: seconds, loadSeconds: 0)
    }

    @available(macOS 26, *)
    private static func transcribeWithAnalyzer(_ url: URL, locale: Locale) async throws -> String {
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.apiError(String(localized: "Apple speech recognition doesn't support this language."))
        }
        let transcriber = DictationTranscriber(locale: supported, preset: .longDictation)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var parts: [String] = []
            for try await result in transcriber.results {
                parts.append(String(result.text.characters).trimmingCharacters(in: .whitespaces))
            }
            return parts.filter { !$0.isEmpty }.joined(separator: " ")
        }
        try await analyzer.start(inputAudioFile: AVAudioFile(forReading: url), finishAfterFile: true)
        let text = try await collector.value
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscription }
        return text
    }

    private static func transcribeWithRecognizer(_ url: URL, locale: Locale) async throws -> String {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { cont in SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) } }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: locale)
        else { throw TranscriptionError.apiError(String(localized: "Allow Speech Recognition for Diduny in System Settings › Privacy & Security.")) }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
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

/// On-device engines usable as a mode's engine (Parakeet V3, Apple).
enum OnDeviceEngines {
    static func make(id: String?) -> (any BenchmarkEngine)? {
        switch id {
        case STTProviderID.parakeet: ParakeetBenchmarkEngine()
        case STTProviderID.appleSpeech: AppleBenchmarkEngine()
        default: nil
        }
    }

    /// The engine when it is ready on this Mac, else nil.
    @MainActor static func engine(id: String?) -> (any BenchmarkEngine)? {
        guard let engine = make(id: id), engine.availability() == .ready else { return nil }
        return engine
    }

    static let notReadyMessage = String(localized: "The selected on-device engine isn't ready on this Mac. Download it in Local Models or pick another engine in Settings › Providers.")
}
