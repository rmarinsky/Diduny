import Foundation

/// Text-frame WebSocket seam so tests can drive the session without a network.
protocol ElevenLabsRealtimeTransport: AnyObject, Sendable {
    func send(_ text: String) async throws
    /// Next text frame; throws when the socket drops or closes.
    func receive() async throws -> String
    /// Closes with code 1000.
    func close()
}

final class URLSessionElevenLabsTransport: ElevenLabsRealtimeTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        while true {
            switch try await task.receive() {
            case let .string(text): return text
            case let .data(data): if let text = String(data: data, encoding: .utf8) { return text }
            @unknown default: continue
            }
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

/// ElevenLabs Scribe v2 Realtime over `wss://api.elevenlabs.io/v1/speech-to-text/realtime`.
/// The key goes only in the `xi-api-key` handshake header. Logs carry counts, never key or text.
final class ElevenLabsRealtimeService: RealtimeTranscriptionProtocol, @unchecked Sendable {
    enum CommitStrategy: String { case manual, vad }

    static let modelID = "scribe_v2_realtime"
    static let previousTextLimit = 50

    private let apiKey: String
    private let commitStrategy: CommitStrategy
    private let keepaliveInterval: TimeInterval
    private let maxReconnects: Int
    /// Meetings: commit pending speech at least this often, so a long monologue never waits on VAD silence.
    private let periodicCommitInterval: TimeInterval?
    /// Meetings: a dropped socket reconnects (within `maxReconnects`) instead of ending the session.
    private let reconnectOnDrop: Bool
    private let makeTransport: (URLRequest) -> ElevenLabsRealtimeTransport
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let lock = NSLock()

    // State guarded by `lock`.
    private var transport: ElevenLabsRealtimeTransport?
    private var request: URLRequest?
    private var connected = false
    private var sessionActive = false
    private var pendingAudio = PreConnectAudioBuffer()
    private var previousTextForNextChunk: String?
    private var committedText = ""
    private var audioSentSinceTick = false
    private var awaitingCommit = false
    private var hasUncommittedPartial = false
    private var commitReceived = false
    /// Manual commits sent this session whose `committed_transcript` has not arrived yet.
    private var unansweredCommits = 0
    /// Earlier commits still owed an answer when Stop's commit was sent; their answers are not Stop's.
    private var commitsBeforeFinalize = 0
    private var tokensAfterCommit = 0
    private var charactersAfterCommit = 0
    private var reconnectAttempts = 0
    private var sampleRate = 16000

    private var outgoing: AsyncStream<String>.Continuation?
    private var senderTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?

    var onTokensReceived: (([RealtimeToken]) -> Void)?
    var onSegmentBoundary: ((RealtimeSegmentBoundary) -> Void)?
    private var onError: ((Error) -> Void)?
    private var onStatus: ((RealtimeConnectionStatus) -> Void)?

    init(
        apiKey: String,
        commitStrategy: CommitStrategy = .manual,
        keepaliveInterval: TimeInterval = 5,
        maxReconnects: Int = 3,
        periodicCommitInterval: TimeInterval? = nil,
        reconnectOnDrop: Bool = false,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        makeTransport: @escaping (URLRequest) -> ElevenLabsRealtimeTransport = { URLSessionElevenLabsTransport(request: $0) }
    ) {
        self.apiKey = apiKey
        self.commitStrategy = commitStrategy
        self.keepaliveInterval = keepaliveInterval
        self.maxReconnects = maxReconnects
        self.periodicCommitInterval = periodicCommitInterval
        self.reconnectOnDrop = reconnectOnDrop
        self.makeTransport = makeTransport
        self.sleep = sleep
    }

    func setConnectionHandlers(
        onError: ((Error) -> Void)?,
        onConnectionStatusChanged: ((RealtimeConnectionStatus) -> Void)?
    ) {
        self.onError = onError
        onStatus = onConnectionStatusChanged
    }

    func clearCallbacks() {
        onTokensReceived = nil
        onSegmentBoundary = nil
        onError = nil
        onStatus = nil
    }

    static func makeRequest(
        apiKey: String,
        languageHints: [String],
        sampleRate: Int,
        commitStrategy: CommitStrategy
    ) -> URLRequest {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var items = [
            URLQueryItem(name: "model_id", value: modelID),
            URLQueryItem(name: "audio_format", value: "pcm_\(sampleRate)"),
            URLQueryItem(name: "commit_strategy", value: commitStrategy.rawValue)
        ]
        let languages = languageHints.filter { $0.lowercased() != "auto" && !$0.isEmpty }
        if let first = languages.first {
            items.append(URLQueryItem(name: "language_code", value: first))
            items += languages.dropFirst().map { URLQueryItem(name: "secondary_languages", value: $0) }
        }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    /// Maps a server error `message_type` to a user outcome; nil for non-error messages.
    static func error(forMessageType type: String) -> ElevenLabsError? {
        switch type {
        case "auth_error": .invalidKey
        case "quota_exceeded": .quotaExceeded
        case "unaccepted_terms", "unaccepted_terms_error": .termsNotAccepted
        case "rate_limited", "commit_throttled", "queue_overflow", "resource_exhausted": .rateLimited
        case "session_time_limit_exceeded", "input_error", "invalid_request", "chunk_size_exceeded",
             "insufficient_audio_activity", "transcriber_error", "error":
            .sessionEnded(code: type)
        default: nil
        }
    }

    // MARK: - Connect

    func connect(
        languageHints: [String],
        strictLanguageHints _: Bool,
        audioConfig: RealtimeAudioConfig,
        translationConfig _: RealtimeTranslationConfig?,
        enableSpeakerDiarization _: Bool
    ) async throws {
        let request = Self.makeRequest(
            apiKey: apiKey,
            languageHints: languageHints,
            sampleRate: audioConfig.sampleRate,
            commitStrategy: commitStrategy
        )
        let (stream, continuation) = AsyncStream<String>.makeStream()
        lock.withLock {
            self.request = request
            sampleRate = audioConfig.sampleRate
            sessionActive = true
            committedText = ""
            reconnectAttempts = 0
            unansweredCommits = 0
            pendingAudio.removeAll()
            previousTextForNextChunk = nil
            outgoing = continuation
        }
        senderTask = Task { [weak self] in
            for await frame in stream {
                guard let transport = self?.lock.withLock({ self?.transport }) else { continue }
                try? await transport.send(frame)
            }
        }
        onStatus?(.connecting)
        do {
            try await openSession()
        } catch {
            await disconnect()
            onStatus?(.failed(error.localizedDescription))
            throw error
        }
        startKeepalive()
        onStatus?(.connected)
    }

    /// Opens a socket, waits for `session_started`, then flushes buffered audio.
    private func openSession() async throws {
        guard let request = lock.withLock({ self.request }) else { return }
        let transport = makeTransport(request)
        let first: String
        do {
            first = try await transport.receive()
        } catch {
            transport.close()
            throw ElevenLabsError.network
        }
        let type = Self.messageType(first)
        guard type == "session_started" else {
            transport.close()
            throw Self.error(forMessageType: type ?? "") ?? ElevenLabsError.invalidResponse
        }
        let buffered: [Data] = lock.withLock {
            self.transport = transport
            connected = true
            var chunks: [Data] = []
            while let chunk = pendingAudio.removeFirst() { chunks.append(chunk) }
            return chunks
        }
        Log.transcription.info("ElevenLabs RT: session started, flushing \(buffered.count) buffered chunks")
        buffered.forEach(enqueueAudio)
        startReceiveLoop(transport)
    }

    // MARK: - Audio

    func sendAudioData(_ data: Data) {
        guard !data.isEmpty else { return }
        let ready: Bool = lock.withLock {
            guard sessionActive else { return false }
            if !connected { pendingAudio.append(data); return false }
            return true
        }
        if ready { enqueueAudio(data) }
    }

    private func enqueueAudio(_ data: Data) {
        let frame: String? = lock.withLock {
            audioSentSinceTick = true
            let previous = previousTextForNextChunk
            previousTextForNextChunk = nil
            return Self.audioFrame(data, commit: false, sampleRate: sampleRate, previousText: previous)
        }
        if let frame { outgoing?.yield(frame) }
    }

    static func audioFrame(_ data: Data, commit: Bool, sampleRate: Int, previousText: String? = nil) -> String? {
        var payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": data.base64EncodedString(),
            "commit": commit,
            "sample_rate": sampleRate
        ]
        if let previousText, !previousText.isEmpty { payload["previous_text"] = previousText }
        guard let json = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        return String(data: json, encoding: .utf8)
    }

    private func startKeepalive() {
        let interval = keepaliveInterval
        let sleep = sleep
        let commitInterval = periodicCommitInterval
        keepaliveTask = Task { [weak self] in
            var sinceCommit: TimeInterval = 0
            while !Task.isCancelled {
                await sleep(interval)
                guard let self, !Task.isCancelled else { return }
                sinceCommit += interval
                if let commitInterval, sinceCommit >= commitInterval {
                    sinceCommit = 0
                    commitPendingSpeech()
                }
                let idle: Bool = lock.withLock {
                    defer { audioSentSinceTick = false }
                    return connected && !audioSentSinceTick
                }
                // 100 ms of silence keeps the server's 15 s idle timer from closing the session.
                if idle { enqueueAudio(Data(count: sampleRate / 10 * 2)) }
            }
        }
    }

    /// Manual commit of the current partial; skipped when nothing is pending or Stop is finalizing.
    private func commitPendingSpeech() {
        let rate: Int? = lock.withLock {
            guard connected, hasUncommittedPartial, !awaitingCommit else { return nil }
            hasUncommittedPartial = false
            unansweredCommits += 1
            return sampleRate
        }
        guard let rate, let frame = Self.audioFrame(Data(), commit: true, sampleRate: rate) else { return }
        outgoing?.yield(frame)
    }

    // MARK: - Receive

    private func startReceiveLoop(_ transport: ElevenLabsRealtimeTransport) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let text = try await transport.receive()
                    await self?.handle(text)
                } catch {
                    self?.handleDrop(transport)
                    return
                }
            }
        }
    }

    private static func messageType(_ text: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["message_type"] as? String
    }

    private func handle(_ text: String) async {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["message_type"] as? String else { return }
        switch type {
        case "partial_transcript":
            guard let partial = json["text"] as? String, !partial.isEmpty else { return }
            lock.withLock { hasUncommittedPartial = true }
            onTokensReceived?([RealtimeToken(text: partial, isFinal: false)])
        case "committed_transcript":
            let committed = (json["text"] as? String) ?? ""
            let (token, boundary): (RealtimeToken?, RealtimeSegmentBoundary) = lock.withLock {
                if unansweredCommits > 0 { unansweredCommits -= 1 }
                let answersStop = awaitingCommit && commitsBeforeFinalize == 0
                if awaitingCommit, commitsBeforeFinalize > 0 { commitsBeforeFinalize -= 1 }
                let boundary: RealtimeSegmentBoundary = answersStop ? .finalize : .endpoint
                if answersStop { commitReceived = true }
                hasUncommittedPartial = false
                guard !committed.isEmpty else { return (nil, boundary) }
                let tokenText = committedText.isEmpty ? committed : " " + committed
                committedText += tokenText
                if awaitingCommit {
                    tokensAfterCommit += 1
                    charactersAfterCommit += tokenText.count
                }
                return (RealtimeToken(text: tokenText, isFinal: true), boundary)
            }
            if let token { onTokensReceived?([token]) }
            onSegmentBoundary?(boundary)
        default:
            guard let error = Self.error(forMessageType: type) else { return }
            Log.transcription.error("ElevenLabs RT: server error \(type)")
            if type == "session_time_limit_exceeded", await reconnect() { return }
            endSession(with: error)
        }
    }

    private func handleDrop(_ transport: ElevenLabsRealtimeTransport) {
        let isCurrent = lock.withLock { self.transport === transport && sessionActive && connected }
        guard isCurrent else { return }
        Log.transcription.warning("ElevenLabs RT: socket dropped")
        guard reconnectOnDrop else { return endSession(with: .network) }
        Task { [weak self] in
            guard let self else { return }
            if await reconnect() { return }
            endSession(with: .network)
        }
    }

    /// Ends the session without reconnecting. Committed text and the recording are kept by the caller.
    private func endSession(with error: ElevenLabsError) {
        let transport: ElevenLabsRealtimeTransport? = lock.withLock {
            connected = false
            sessionActive = false
            let current = self.transport
            self.transport = nil
            return current
        }
        transport?.close()
        keepaliveTask?.cancel()
        onError?(error)
        onStatus?(.failed(error.localizedDescription))
    }

    /// New session after the provider's time limit, seeded with the tail of the committed text.
    private func reconnect() async -> Bool {
        let attempt: Int? = lock.withLock {
            guard sessionActive, reconnectAttempts < maxReconnects else { return nil }
            reconnectAttempts += 1
            connected = false
            transport?.close()
            transport = nil
            unansweredCommits = 0
            previousTextForNextChunk = committedText.isEmpty
                ? nil : String(committedText.suffix(Self.previousTextLimit))
            return reconnectAttempts
        }
        guard let attempt else { return false }
        onStatus?(.reconnecting(attempt: attempt))
        do {
            try await openSession()
            // Bound consecutive failures only; a long meeting may hit the time limit many times.
            lock.withLock { reconnectAttempts = 0 }
            onStatus?(.connected)
            return true
        } catch {
            Log.transcription.error("ElevenLabs RT: reconnect \(attempt) failed")
            return false
        }
    }

    // MARK: - Finalize / disconnect

    func finalize(profile: RealtimeFinalizeProfile) async -> RealtimeFinalizeResult {
        let started = Date()
        let canCommit: Bool = lock.withLock {
            guard connected, !awaitingCommit else { return false }
            awaitingCommit = true
            commitReceived = false
            commitsBeforeFinalize = unansweredCommits
            unansweredCommits += 1
            tokensAfterCommit = 0
            charactersAfterCommit = 0
            return true
        }
        guard canCommit, let frame = Self.audioFrame(Data(), commit: true, sampleRate: lock.withLock { sampleRate })
        else { return .skipped }
        outgoing?.yield(frame)

        let deadline = started.addingTimeInterval(profile.timeoutSeconds)
        var received = false
        while Date() < deadline {
            received = lock.withLock { commitReceived || !connected }
            if received { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let (gotCommit, tokens, characters) = lock.withLock {
            awaitingCommit = false
            return (commitReceived, tokensAfterCommit, charactersAfterCommit)
        }
        return RealtimeFinalizeResult(
            profileName: profile.name,
            didReceiveFinishedSignal: gotCommit,
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            tokensAfterFinalize: tokens,
            charactersAfterFinalize: characters,
            timedOut: !gotCommit,
            quietWindowReached: gotCommit
        )
    }

    func disconnect() async {
        let transport: ElevenLabsRealtimeTransport? = lock.withLock {
            connected = false
            sessionActive = false
            pendingAudio.removeAll()
            let current = self.transport
            self.transport = nil
            return current
        }
        keepaliveTask?.cancel()
        receiveTask?.cancel()
        outgoing?.finish()
        // Let queued frames (e.g. the commit) drain before closing.
        await senderTask?.value
        transport?.close()
        onStatus?(.disconnected)
    }
}
