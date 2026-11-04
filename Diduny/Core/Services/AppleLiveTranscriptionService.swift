import AVFoundation
import Foundation
import Speech

/// Live on-device transcription with Apple speech recognition, behind the same protocol as
/// Diduny Cloud and ElevenLabs. macOS 26+: SpeechAnalyzer + DictationTranscriber (volatile + final
/// results). macOS 14–25: SFSpeechRecognizer, restarted every ~55 s so a possible one-minute
/// on-device limit never drops words. Audio in: 16 kHz mono PCM16, as from the app's pipelines.
final class AppleLiveTranscriptionService: RealtimeTranscriptionProtocol, @unchecked Sendable {
    var onTokensReceived: (([RealtimeToken]) -> Void)?
    var onSegmentBoundary: ((RealtimeSegmentBoundary) -> Void)?

    private let farField: Bool
    private let lock = NSLock()
    private var pending: [Data] = []
    private var backend: Backend?
    private var onError: ((Error) -> Void)?
    private var onStatus: ((RealtimeConnectionStatus) -> Void)?

    /// - Parameter farField: meetings (system audio, distant voices).
    init(farField: Bool = false) {
        self.farField = farField
    }

    func setConnectionHandlers(
        onError: ((Error) -> Void)?,
        onConnectionStatusChanged: ((RealtimeConnectionStatus) -> Void)?
    ) {
        self.onError = onError
        onStatus = onConnectionStatusChanged
    }

    func connect(
        languageHints: [String],
        strictLanguageHints _: Bool,
        audioConfig _: RealtimeAudioConfig,
        translationConfig _: RealtimeTranslationConfig?,
        enableSpeakerDiarization _: Bool
    ) async throws {
        let locale = Locale(identifier: languageHints.first ?? BenchmarkRunner.defaultLanguage)
        let emit: @Sendable (String, Bool) -> Void = { [weak self] text, isFinal in
            guard let self, !text.isEmpty else { return }
            onTokensReceived?([RealtimeToken(text: isFinal ? text + " " : text, isFinal: isFinal)])
            if isFinal { onSegmentBoundary?(.endpoint) }
        }
        let backend: Backend
        if #available(macOS 26, *) {
            backend = try await AnalyzerBackend.start(locale: locale, farField: farField, emit: emit)
        } else {
            backend = try await RecognizerBackend.start(locale: locale, emit: emit, onError: { [weak self] in self?.onError?($0) })
        }
        lock.lock()
        self.backend = backend
        let buffered = pending
        pending = []
        lock.unlock()
        for data in buffered { backend.append(data) }
        onStatus?(.connected)
    }

    func sendAudioData(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if let backend { backend.append(data) } else { pending.append(data) }
    }

    func finalize(profile: RealtimeFinalizeProfile) async -> RealtimeFinalizeResult {
        let start = Date()
        lock.lock()
        let backend = backend
        lock.unlock()
        await backend?.finish()
        onSegmentBoundary?(.finalize)
        return RealtimeFinalizeResult(
            profileName: profile.name,
            didReceiveFinishedSignal: backend != nil,
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            tokensAfterFinalize: 0,
            charactersAfterFinalize: 0,
            timedOut: false,
            quietWindowReached: true
        )
    }

    func disconnect() async {
        lock.lock()
        let backend = backend
        self.backend = nil
        pending = []
        lock.unlock()
        backend?.cancel()
        onStatus?(.disconnected)
    }

    func clearCallbacks() {
        onTokensReceived = nil
        onSegmentBoundary = nil
        onError = nil
        onStatus = nil
    }

    /// 16 kHz mono PCM16 bytes → buffer in `format` (converted when the engine wants another format).
    static func buffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0,
              let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames)
        else { return nil }
        input.frameLength = frames
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let dest = input.int16ChannelData?[0] {
                memcpy(dest, base, Int(frames) * 2)
            }
        }
        if format == source { return input }
        guard let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(Double(frames) * format.sampleRate / 16000) + 16
              )
        else { return nil }
        var consumed = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        return output
    }
}

private protocol Backend: AnyObject, Sendable {
    func append(_ data: Data)
    func finish() async
    func cancel()
}

// MARK: - macOS 26+: SpeechAnalyzer

@available(macOS 26, *)
private final class AnalyzerBackend: Backend, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    private let results: Task<Void, Never>

    private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat, results: Task<Void, Never>) {
        self.analyzer = analyzer
        self.input = input
        self.format = format
        self.results = results
    }

    static func start(locale: Locale, farField: Bool, emit: @escaping @Sendable (String, Bool) -> Void) async throws -> AnalyzerBackend {
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.apiError(String(localized: "Apple speech recognition doesn't support this language."))
        }
        let transcriber = DictationTranscriber(
            locale: supported,
            contentHints: farField ? [.farField] : [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.apiError(String(localized: "Apple speech recognition doesn't support this language."))
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let results = Task {
            do {
                for try await result in transcriber.results {
                    // Volatile text is cumulative since the last final: the caller replaces it.
                    emit(String(result.text.characters).trimmingCharacters(in: .whitespaces), result.isFinal)
                }
            } catch {
                Log.transcription.warning("Apple live results ended: \(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: stream)
        return AnalyzerBackend(analyzer: analyzer, input: continuation, format: format, results: results)
    }

    func append(_ data: Data) {
        guard let buffer = AppleLiveTranscriptionService.buffer(from: data, format: format) else { return }
        input.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await results.value
    }

    func cancel() {
        input.finish()
        results.cancel()
        Task { await analyzer.cancelAndFinishNow() }
    }
}

// MARK: - macOS 14–25: SFSpeechRecognizer with rotation

private final class RecognizerBackend: Backend, @unchecked Sendable {
    /// Restart before the possible one-minute on-device limit.
    private static let rotateAfterSamples = 16000 * 55

    private let recognizer: SFSpeechRecognizer
    private let emit: @Sendable (String, Bool) -> Void
    private let onError: @Sendable (Error) -> Void
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var samplesInRequest = 0
    private var openTasks = 0
    private var drained: CheckedContinuation<Void, Never>?
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    private init(recognizer: SFSpeechRecognizer, emit: @escaping @Sendable (String, Bool) -> Void, onError: @escaping @Sendable (Error) -> Void) {
        self.recognizer = recognizer
        self.emit = emit
        self.onError = onError
    }

    static func start(
        locale: Locale,
        emit: @escaping @Sendable (String, Bool) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws -> RecognizerBackend {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { cont in SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) } }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriptionError.apiError(String(localized: "Allow Speech Recognition for Diduny in System Settings › Privacy & Security."))
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.apiError(String(localized: "Apple speech recognition doesn't support this language."))
        }
        let backend = RecognizerBackend(recognizer: recognizer, emit: emit, onError: onError)
        backend.lock.lock()
        backend.startRequest()
        backend.lock.unlock()
        return backend
    }

    /// Caller holds `lock`.
    private func startRequest() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        samplesInRequest = 0
        openTasks += 1
        var done = false
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, !done else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                emit(text, result.isFinal)
                if result.isFinal { done = true; taskEnded() }
            } else if let error {
                done = true
                // "No speech" on a rotated, silent request is not an error worth surfacing.
                if (error as NSError).code != 1110 { onError(error) }
                taskEnded()
            }
        }
    }

    private func taskEnded() {
        lock.lock()
        openTasks -= 1
        let continuation = openTasks == 0 ? drained : nil
        if continuation != nil { drained = nil }
        lock.unlock()
        continuation?.resume()
    }

    func append(_ data: Data) {
        guard let buffer = AppleLiveTranscriptionService.buffer(from: data, format: format) else { return }
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
        samplesInRequest += Int(buffer.frameLength)
        if samplesInRequest >= Self.rotateAfterSamples {
            // Close this request (its final result still arrives) and continue in a fresh one.
            request?.endAudio()
            startRequest()
        }
    }

    func finish() async {
        lock.lock()
        request?.endAudio()
        request = nil
        let open = openTasks
        lock.unlock()
        guard open > 0 else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if openTasks == 0 { lock.unlock(); cont.resume(); return }
            drained = cont
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        request = nil
        lock.unlock()
    }
}
