import Foundation
import os

final class CloudRealtimeService: NSObject, @unchecked Sendable {
    private let loadProxyBaseURL: () -> String
    private let loadAccessToken: () async -> String?
    private let loadUsage: () async -> UsageResponse?

    init(
        proxyBaseURL: @escaping () -> String = { SettingsStorage.shared.proxyBaseURL },
        accessToken: @escaping () async -> String? = { await AuthService.shared.getAccessToken() },
        cachedUsage: @escaping () async -> UsageResponse? = { await UsageService.shared.cachedUsage }
    ) {
        loadProxyBaseURL = proxyBaseURL
        loadAccessToken = accessToken
        loadUsage = cachedUsage
        super.init()
    }

    private var wsURL: String {
        let proxyBase = loadProxyBaseURL()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        return "\(proxyBase)/api/v1/realtime"
    }
    private var webSocketTask: URLSessionWebSocketTask?
    /// One URLSession for the service's lifetime, so the TLS session cache
    /// survives across connections (TLS 1.3 resumption saves a round trip on
    /// every recording start). Never invalidate it — invalidateAndCancel would
    /// permanently break all future connects. The session retains its delegate
    /// (self); acceptable, this service lives as long as the app. Guarded by
    /// lifecycleLock.
    private var _sharedSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    /// In-flight reconnect (sleeping during backoff). Held so disconnect() can cancel it —
    /// otherwise a drop that schedules a reconnect just before disconnect resurrects the
    /// socket after teardown and loops forever with no audio source. Guarded by lifecycleLock.
    private var reconnectTask: Task<Void, Never>?
    private var proxyReady = false
    /// Resumed exactly once (take-and-nil under lifecycleLock) by whichever
    /// fires first: proxy_ready, a proxy error frame, the timeout watchdog,
    /// or disconnect.
    private var proxyReadyContinuation: CheckedContinuation<Void, Error>?
    private var proxyReadyTimeoutTask: Task<Void, Never>?
    /// Audio produced while the socket is connecting or in reconnect backoff.
    /// Flushed in order on connect, so the first seconds of speech reach
    /// transcription instead of being dropped. Guarded by lifecycleLock.
    private var pendingAudio = PreConnectAudioBuffer()
    private var didWarnPendingAudioOverflow = false
    /// True from connect() until disconnect() or a terminal failure — the
    /// window in which buffering audio is worthwhile. Guarded by lifecycleLock.
    private var sessionActive = false
    /// True while the post-connect flush drains pendingAudio. New audio must
    /// join the back of the queue during a flush, never jump straight to the
    /// socket, or chunks would arrive out of order. Guarded by lifecycleLock.
    private var flushingPendingAudio = false
    /// Phase timings for the in-flight connect. Guarded by lifecycleLock; the
    /// URLSession delegate and receive loop close phases from other threads.
    private var currentConnectMetrics: ConnectMetrics?

    private var isConnected = false
    private var isSessionEnding = false
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 3

    private var languageHints: [String] = []
    private var strictLanguageHints = false
    private var audioConfig: RealtimeAudioConfig = .defaultPCM16kMono
    private var translationConfig: RealtimeTranslationConfig?
    private var enableSpeakerDiarization = true
    private let finalizeStateLock = NSLock()
    private let lifecycleLock = NSLock()
    private var awaitingFinalizeResponse = false
    private var didReceiveFinishedSignal = false
    private var lastRealtimeTokenAt: Date?
    private var finalizeTokenCount = 0
    private var finalizeCharacterCount = 0

    private var _onTokensReceived: (([RealtimeToken]) -> Void)?
    private var _onError: ((Error) -> Void)?
    private var _onConnectionStatusChanged: ((RealtimeConnectionStatus) -> Void)?
    private var _onSegmentBoundary: ((RealtimeSegmentBoundary) -> Void)?

    var onTokensReceived: (([RealtimeToken]) -> Void)? {
        get { finalizeStateLock.lock(); defer { finalizeStateLock.unlock() }; return _onTokensReceived }
        set { finalizeStateLock.lock(); defer { finalizeStateLock.unlock() }; _onTokensReceived = newValue }
    }

    var onError: ((Error) -> Void)? {
        get { finalizeStateLock.lock(); defer { finalizeStateLock.unlock() }; return _onError }
        set { finalizeStateLock.lock(); defer { finalizeStateLock.unlock() }; _onError = newValue }
    }

    var onConnectionStatusChanged: ((RealtimeConnectionStatus) -> Void)? {
        get { finalizeStateLock.lock(); defer { finalizeStateLock.unlock() }; return _onConnectionStatusChanged }
        set { finalizeStateLock.lock(); defer { finalizeStateLock.unlock() }; _onConnectionStatusChanged = newValue }
    }

    var onSegmentBoundary: ((RealtimeSegmentBoundary) -> Void)? {
        get { finalizeStateLock.lock(); defer { finalizeStateLock.unlock() }; return _onSegmentBoundary }
        set { finalizeStateLock.lock(); defer { finalizeStateLock.unlock() }; _onSegmentBoundary = newValue }
    }

    func setConnectionHandlers(
        onError: ((Error) -> Void)?,
        onConnectionStatusChanged: ((RealtimeConnectionStatus) -> Void)?
    ) {
        finalizeStateLock.lock()
        _onError = onError
        _onConnectionStatusChanged = onConnectionStatusChanged
        finalizeStateLock.unlock()
    }

    private func connectionHandlers() -> (
        onError: ((Error) -> Void)?,
        onConnectionStatusChanged: ((RealtimeConnectionStatus) -> Void)?
    ) {
        finalizeStateLock.lock()
        defer { finalizeStateLock.unlock() }
        return (_onError, _onConnectionStatusChanged)
    }

    // MARK: - Connect

    func connect(
        languageHints: [String] = [],
        strictLanguageHints: Bool = false,
        audioConfig: RealtimeAudioConfig = .defaultPCM16kMono,
        translationConfig: RealtimeTranslationConfig? = nil,
        enableSpeakerDiarization: Bool = true
    ) async throws {
        self.languageHints = languageHints
        self.strictLanguageHints = strictLanguageHints
        self.audioConfig = audioConfig
        self.translationConfig = translationConfig
        self.enableSpeakerDiarization = enableSpeakerDiarization
        // Fresh session: start buffering incoming audio right away, so speech
        // during the connect handshake is delivered once the socket is up.
        lifecycleLock.lock()
        reconnectAttempt = 0
        sessionActive = true
        pendingAudio.removeAll()
        didWarnPendingAudioOverflow = false
        lifecycleLock.unlock()
        try await connectWebSocket()
    }

    private func connectWebSocket() async throws {
        // Pre-check cached usage to avoid unnecessary connection attempt
        if let usage = await loadUsage(), !usage.hasUnlimitedAccess,
           let remaining = usage.remainingMs, remaining <= 0 {
            throw RealtimeTranscriptionError.usageLimitExceeded(
                usedHours: usage.usedHours, limitHours: usage.limitHours ?? UsageService.freeCloudLimitHours
            )
        }

        // Clean up any existing connection before reconnecting. Note:
        // pendingAudio is deliberately NOT cleared — audio buffered during a
        // reconnect backoff must survive into the new connection.
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        lifecycleLock.lock()
        audioBytesSent = 0
        audioChunkCount = 0
        isSessionEnding = false
        proxyReady = false
        lifecycleLock.unlock()

        onConnectionStatusChanged?(.connecting)

        let metrics = ConnectMetrics(label: "[Cloud RT] connect")
        lifecycleLock.lock()
        currentConnectMetrics = metrics
        lifecycleLock.unlock()
        // Idempotent: the success path below finishes with "ok" first, so this
        // only fires when an error path unwinds out of connectWebSocket().
        defer { metrics.finish() }

        let session = sharedSession()

        var wsURLString = wsURL

        // Pass auth token as query param (WebSocket headers are limited)
        metrics.begin(.tokenFetch)
        let accessToken = await loadAccessToken()
        metrics.end(.tokenFetch)
        if let accessToken {
            let separator = wsURLString.contains("?") ? "&" : "?"
            wsURLString += "\(separator)token=\(accessToken)"
        }

        guard let url = URL(string: wsURLString),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            throw RealtimeTranscriptionError.connectionFailed("Invalid WebSocket URL: \(wsURLString)")
        }

        // URLSession.webSocketTask(with:) can throw an ObjC NSException that Swift
        // cannot catch with do/catch. Wrap in ObjC exception catcher to prevent crash.
        var task: URLSessionWebSocketTask?
        do {
            try ObjCExceptionCatcher.catchException {
                task = session.webSocketTask(with: url)
            }
        } catch {
            throw RealtimeTranscriptionError.connectionFailed(
                "WebSocket task creation failed: \(error.localizedDescription)"
            )
        }

        guard let task else {
            throw RealtimeTranscriptionError.connectionFailed("Failed to create WebSocket task")
        }

        self.webSocketTask = task
        metrics.begin(.wsUpgrade) // ended by didOpenWithProtocol on the delegate queue
        task.resume()

        let config = Self.makeConnectionConfig(
            languageHints: languageHints,
            strictLanguageHints: strictLanguageHints,
            audioConfig: audioConfig,
            translationConfig: translationConfig,
            enableSpeakerDiarization: enableSpeakerDiarization
        )

        let configData = try JSONSerialization.data(withJSONObject: config)
        let configString = String(data: configData, encoding: .utf8) ?? "{}"

        NSLog("[Cloud RT] Sending config: %@", configString)
        metrics.begin(.configSend)
        do {
            try await task.send(.string(configString))
        } catch {
            // A refused upgrade (e.g. HTTP 402 usage limit) surfaces as the first
            // send/receive throwing. Map 402 to a typed usage error so the caller
            // shows "limit reached" instead of a generic connection failure.
            if let usageError = await usageLimitUpgradeError() {
                throw usageError
            }
            throw error
        }
        metrics.end(.configSend)
        NSLog("[Cloud RT] Config sent successfully, WebSocket connected")

        lifecycleLock.lock()
        isConnected = true
        // Route new audio to the back of the queue until the flush drains it.
        flushingPendingAudio = !pendingAudio.isEmpty
        let needsFlush = flushingPendingAudio
        lifecycleLock.unlock()

        startReceiveLoop()
        startPingLoop()

        // Deliver audio captured while connecting. Safe before proxy_ready:
        // the proxy buffers frames until Soniox is ready (1MB server cap).
        if needsFlush {
            await flushPendingAudio(task: task)
        }

        // Wait for proxy_ready before marking connected.
        metrics.begin(.proxyReadyWait) // ended by parseResponse when proxy_ready arrives
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lifecycleLock.lock()
                if proxyReady {
                    lifecycleLock.unlock()
                    continuation.resume()
                    return
                }
                proxyReadyContinuation = continuation
                proxyReadyTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    self?.resumeProxyReady(with: .failure(
                        RealtimeTranscriptionError.connectionFailed("Proxy did not send ready signal")
                    ))
                }
                lifecycleLock.unlock()
            }
        } catch {
            await disconnect()
            throw error
        }

        metrics.finish(outcome: "ok")
        onConnectionStatusChanged?(.connected)
    }

    /// Thread-safe accessor for the process-lifetime URLSession (see _sharedSession).
    private func sharedSession() -> URLSession {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if let session = _sharedSession {
            return session
        }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        _sharedSession = session
        return session
    }

    /// Resolves the proxy_ready wait exactly once; later calls are no-ops.
    private func resumeProxyReady(with result: Result<Void, Error>) {
        lifecycleLock.lock()
        let continuation = proxyReadyContinuation
        proxyReadyContinuation = nil
        let timeoutTask = proxyReadyTimeoutTask
        proxyReadyTimeoutTask = nil
        lifecycleLock.unlock()

        timeoutTask?.cancel()
        switch result {
        case .success:
            continuation?.resume()
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }

    /// Drains pendingAudio to the socket in FIFO order. Sends are awaited so
    /// ordering is preserved; audio arriving mid-flush is appended behind the
    /// queued chunks by sendAudioData (flushingPendingAudio gate).
    private func flushPendingAudio(task: URLSessionWebSocketTask) async {
        var flushedChunks = 0
        var flushedBytes = 0
        while true {
            lifecycleLock.lock()
            guard isConnected, let chunk = pendingAudio.removeFirst() else {
                flushingPendingAudio = false
                lifecycleLock.unlock()
                break
            }
            audioBytesSent += chunk.count
            audioChunkCount += 1
            lifecycleLock.unlock()

            do {
                try await task.send(.data(chunk))
                flushedChunks += 1
                flushedBytes += chunk.count
            } catch {
                Log.transcription.error("Cloud RT: Buffered audio flush failed - \(error.localizedDescription)")
                // The connection is failing; the receive loop / delegate will
                // drive reconnect, and remaining chunks stay buffered for it.
                lifecycleLock.lock()
                flushingPendingAudio = false
                lifecycleLock.unlock()
                break
            }
        }
        if flushedChunks > 0 {
            NSLog("[Cloud RT] Flushed %d buffered audio chunks (%d bytes)", flushedChunks, flushedBytes)
        }
    }

    // MARK: - Send Audio Data

    private var audioBytesSent: Int = 0
    private var audioChunkCount: Int = 0

    func sendAudioData(_ data: Data) {
        guard !data.isEmpty else { return }

        // Capture task reference under the lock so we don't race with disconnect.
        // Do NOT hold the lock while calling task.send (may block on internal queues).
        lifecycleLock.lock()
        // Not connected yet (connecting or reconnect backoff), or a flush is
        // still draining: buffer so nothing is lost and ordering holds.
        if !isConnected || flushingPendingAudio || !pendingAudio.isEmpty {
            guard sessionActive else {
                lifecycleLock.unlock()
                return
            }
            pendingAudio.append(data)
            let overflowed = pendingAudio.didOverflow && !didWarnPendingAudioOverflow
            if overflowed {
                didWarnPendingAudioOverflow = true
            }
            lifecycleLock.unlock()
            if overflowed {
                Log.transcription.warning("Cloud RT: pre-connect audio buffer overflow — dropping oldest audio")
            }
            return
        }
        guard let task = webSocketTask else {
            lifecycleLock.unlock()
            return
        }
        audioBytesSent += data.count
        audioChunkCount += 1
        let chunkNum = audioChunkCount
        let totalBytes = audioBytesSent
        lifecycleLock.unlock()

        if chunkNum <= 5 || chunkNum % 100 == 0 {
            NSLog(
                "[Cloud RT] Sending audio chunk #%d, size=%d, total=%d bytes",
                chunkNum,
                data.count,
                totalBytes
            )
        }

        task.send(.data(data)) { [weak self] error in
            if let error {
                Log.transcription.error("Cloud RT: Send error - \(error.localizedDescription)")
                self?.onError?(error)
            }
        }
    }

    // MARK: - Finalize

    func finalize(profile: RealtimeFinalizeProfile = .safe) async -> RealtimeFinalizeResult {
        guard isConnected, let task = webSocketTask else {
            return RealtimeFinalizeResult(
                profileName: profile.name,
                didReceiveFinishedSignal: false,
                durationMs: 0,
                tokensAfterFinalize: 0,
                charactersAfterFinalize: 0,
                timedOut: false,
                quietWindowReached: true
            )
        }

        // Record Stop before any suspension: close may precede finished processing.
        lifecycleLock.lock()
        isSessionEnding = true
        lifecycleLock.unlock()

        let startedAt = Date()
        setFinalizeState(awaiting: true, finished: false)

        do {
            let finalizePayloadData = try JSONSerialization.data(withJSONObject: ["type": "finalize"])
            if let finalizePayload = String(data: finalizePayloadData, encoding: .utf8) {
                try await task.send(.string(finalizePayload))
                Log.transcription.info("Cloud RT: Finalize control message sent (\(profile.name))")
                if profile.controlMessageDelayMs > 0 {
                    try? await Task.sleep(for: .milliseconds(profile.controlMessageDelayMs))
                }
            }

            // Soniox ends a stream only on empty text; empty binary is audio.
            try await task.send(.string(""))
            Log.transcription.info("Cloud RT: Empty frame sent (finalize)")

            // Wait for explicit finished signal and a short quiet window for final tokens.
            let deadline = Date().addingTimeInterval(profile.timeoutSeconds)

            while Date() < deadline {
                let snapshot = readFinalizeState()
                let hasQuietWindow = hasFinalizeQuietWindow(
                    snapshot: snapshot,
                    quietWindowSeconds: profile.quietWindowSeconds
                )

                if snapshot.finished && hasQuietWindow {
                    let result = makeFinalizeResult(
                        profile: profile,
                        startedAt: startedAt,
                        snapshot: snapshot,
                        timedOut: false,
                        quietWindowReached: true
                    )
                    setFinalizeState(awaiting: false, finished: false)
                    logFinalizeResult(result)
                    return result
                }

                try? await Task.sleep(for: .milliseconds(50))
            }

            let timedOutSnapshot = readFinalizeState()
            let quietWindowReached = hasFinalizeQuietWindow(
                snapshot: timedOutSnapshot,
                quietWindowSeconds: profile.quietWindowSeconds
            )
            let result = makeFinalizeResult(
                profile: profile,
                startedAt: startedAt,
                snapshot: timedOutSnapshot,
                timedOut: true,
                quietWindowReached: quietWindowReached
            )
            setFinalizeState(awaiting: false, finished: false)
            if !timedOutSnapshot.finished {
                Log.transcription.warning("Cloud RT: Finalize timeout - finished signal was not received")
            } else {
                Log.transcription.warning("Cloud RT: Finalize timeout - finished received but quiet window not reached")
            }
            logFinalizeResult(result)
            return result
        } catch {
            Log.transcription.error("Cloud RT: Finalize error - \(error.localizedDescription)")
            let snapshot = readFinalizeState()
            let result = makeFinalizeResult(
                profile: profile,
                startedAt: startedAt,
                snapshot: snapshot,
                timedOut: false,
                quietWindowReached: false
            )
            setFinalizeState(awaiting: false, finished: false)
            logFinalizeResult(result)
            return result
        }
    }

    // MARK: - Disconnect

    func disconnect() async {
        Log.transcription.info("Cloud RT: Disconnecting...")

        // Unblock a connect() stuck waiting for proxy_ready.
        resumeProxyReady(with: .failure(
            RealtimeTranscriptionError.connectionFailed("Disconnected while connecting")
        ))

        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        lifecycleLock.lock()
        let task = webSocketTask
        webSocketTask = nil
        isConnected = false
        sessionActive = false
        pendingAudio.removeAll()
        flushingPendingAudio = false
        // Kill any reconnect scheduled by a drop that raced just before this disconnect.
        reconnectTask?.cancel()
        reconnectTask = nil
        lifecycleLock.unlock()

        task?.cancel(with: .normalClosure, reason: nil)
        // The shared URLSession stays alive: its TLS session cache makes the
        // next connect cheaper, and invalidating it would break future connects.
        onConnectionStatusChanged?(.disconnected)

        Log.transcription.info("Cloud RT: Disconnected")
    }

    /// Drops all four session callbacks. Call from the owning teardown path
    /// once the session is truly over — stale closures from a finished session
    /// otherwise keep receiving tokens/status (e.g. from a racing reconnect)
    /// and retain whatever they captured. NOT called inside disconnect():
    /// reconnect-failure paths disconnect first and then report .failed
    /// through these callbacks.
    func clearCallbacks() {
        finalizeStateLock.lock()
        _onTokensReceived = nil
        _onError = nil
        _onConnectionStatusChanged = nil
        _onSegmentBoundary = nil
        finalizeStateLock.unlock()
    }

    private func resetReconnectAttempts() {
        lifecycleLock.lock()
        reconnectAttempt = 0
        lifecycleLock.unlock()
    }

    /// Stops buffering and drops pending audio — the session has terminally
    /// failed and nothing will consume the buffer.
    private func endBufferingSession() {
        lifecycleLock.lock()
        sessionActive = false
        pendingAudio.removeAll()
        flushingPendingAudio = false
        lifecycleLock.unlock()
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                guard let task = self.webSocketTask else { break }

                do {
                    let message = try await task.receive()
                    self.handleMessage(message)
                } catch {
                    if Task.isCancelled { break }
                    NSLog("[Cloud RT] Receive error: %@", error.localizedDescription)
                    // Note: server-initiated closes (including 1001) also fire
                    // urlSession(_:webSocketTask:didCloseWith:reason:) on the delegate,
                    // which calls handleDisconnect(closeCode:) with the actual code.
                    // The receive loop fires a generic error without the close code,
                    // so we call handleDisconnect with no code here to avoid a
                    // double-reconnect race — the delegate path wins for close-code routing.
                    self.handleDisconnect(closeCode: nil)
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .string(text):
            NSLog("[Cloud RT] Received message: %@", String(text.prefix(300)))
            parseResponse(text)
        case let .data(data):
            NSLog("[Cloud RT] Received binary data: %d bytes", data.count)
            if let text = String(data: data, encoding: .utf8) {
                parseResponse(text)
            }
        @unknown default:
            break
        }
    }

    private func parseResponse(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        // Handle proxy_ready signal
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["type"] as? String == "proxy_ready" {
            lifecycleLock.lock()
            proxyReady = true
            let metrics = currentConnectMetrics
            lifecycleLock.unlock()
            metrics?.end(.proxyReadyWait)
            resumeProxyReady(with: .success(()))
            NSLog("[Cloud RT] Received proxy_ready signal")
            return
        }

        // Handle proxy error frames
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorMsg = json["error"] as? String,
           json["tokens"] == nil {
            let error = RealtimeTranscriptionError.connectionFailed(errorMsg)
            Log.transcription.error("Cloud RT: Proxy error - \(errorMsg)")
            // An error frame before proxy_ready means the connect failed —
            // fail it now instead of waiting out the 10s timeout.
            resumeProxyReady(with: .failure(error))
            onError?(error)
            onConnectionStatusChanged?(.failed(errorMsg))
            return
        }

        do {
            let response = try JSONDecoder().decode(RealtimeResponse.self, from: data)

            if let errorMessage = response.errorMessage {
                let code = response.errorCode ?? "unknown"
                let error = RealtimeTranscriptionError.connectionFailed("\(code): \(errorMessage)")
                Log.transcription.error("Cloud RT: Server error - \(code): \(errorMessage)")
                onError?(error)
                onConnectionStatusChanged?(.failed(error.localizedDescription))
                return
            }

            if let apiTokens = response.tokens, !apiTokens.isEmpty {
                var bufferedTokens: [RealtimeToken] = []
                for token in apiTokens {
                    guard !token.text.isEmpty else { continue }

                    if let boundary = segmentBoundary(from: token.text) {
                        // Flush buffered tokens before emitting boundary to preserve ordering
                        if !bufferedTokens.isEmpty {
                            markTokenArrival(tokens: bufferedTokens)
                            onTokensReceived?(bufferedTokens)
                            bufferedTokens.removeAll()
                        }
                        onSegmentBoundary?(boundary)
                        continue
                    }

                    bufferedTokens.append(
                        RealtimeToken(
                            text: token.text,
                            isFinal: token.isFinal,
                            speaker: token.speaker,
                            startMs: token.startMs ?? 0,
                            endMs: token.endMs ?? 0,
                            language: token.language,
                            sourceLanguage: token.sourceLanguage,
                            translationStatus: token.translationStatus
                        )
                    )
                }

                if !bufferedTokens.isEmpty {
                    markTokenArrival(tokens: bufferedTokens)
                    onTokensReceived?(bufferedTokens)
                }
            }

            if response.finished == true {
                markFinishedSignalReceived()
                Log.transcription.info("Cloud RT: Received finished signal")
                onSegmentBoundary?(.endpoint)
            }
        } catch {
            Log.transcription.error("Cloud RT: Parse error - \(error.localizedDescription), text: \(text.prefix(200))")
        }
    }

    // MARK: - Ping

    private func startPingLoop() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                self?.webSocketTask?.sendPing { error in
                    if let error {
                        Log.transcription.warning("Cloud RT: Ping failed - \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Reconnect

    /// If the last WS upgrade was refused with HTTP 402, map it to a typed usage
    /// error (using the best usage numbers we have) and kick off a refresh so the
    /// UI shows accurate figures shortly. Returns nil for any other status.
    private func usageLimitUpgradeError() async -> RealtimeTranscriptionError? {
        guard (webSocketTask?.response as? HTTPURLResponse)?.statusCode == 402 else {
            return nil
        }
        let usage = await UsageService.shared.cachedUsage
        await UsageService.shared.refresh()
        return .usageLimitExceeded(
            usedHours: usage?.usedHours ?? 0,
            limitHours: usage?.limitHours ?? UsageService.freeCloudLimitHours
        )
    }

    /// Binds a delayed 402 report to the callbacks that owned the failed connection.
    /// A later recording may replace the service callbacks while usage is loading.
    @discardableResult
    func reportUsageLimit(
        loadCachedUsage: @escaping () async -> UsageResponse? = {
            UsageService.shared.cachedUsage
        },
        refreshUsage: @escaping () async -> Void = {
            _ = await UsageService.shared.refresh()
        }
    ) -> Task<Void, Never> {
        let handlers = connectionHandlers()
        return Task {
            let usage = await loadCachedUsage()
            handlers.onError?(RealtimeTranscriptionError.usageLimitExceeded(
                usedHours: usage?.usedHours ?? 0,
                limitHours: usage?.limitHours ?? UsageService.freeCloudLimitHours
            ))
            handlers.onConnectionStatusChanged?(.failed("Cloud usage limit reached"))
            await refreshUsage()
        }
    }

    /// Called when the receive loop exits due to an error or a server-initiated close.
    ///
    /// ADR-0004 edge cases handled here:
    /// - `1001 Going Away` (proxy 8-hour cap or rolling restart): treat as graceful session end,
    ///   save partial transcript, show non-error UI, do NOT auto-reconnect.
    /// - `401` from proxy on reconnect: refresh the session silently, retry once.
    ///   Never loop — if the refresh fails the user is prompted to re-login.
    private func handleDisconnect(closeCode: URLSessionWebSocketTask.CloseCode? = nil) {
        // Atomic check-and-clear prevents two concurrent callers (receive loop error
        // + URLSessionWebSocketDelegate) from both passing the guard and double-reconnecting.
        lifecycleLock.lock()
        guard isConnected else { lifecycleLock.unlock(); return }
        isConnected = false
        let endingSession = isSessionEnding
        lifecycleLock.unlock()

        // A refused WS upgrade (HTTP 402 usage limit) lands here via the receive
        // loop with no close code. Reconnecting is futile — the server will keep
        // refusing — and would surface a generic "Connection lost" instead of the
        // real reason. Detect it synchronously to stop the reconnect, then surface
        // the typed usage error with the best numbers we have.
        // Whatever path led here, a connect() awaiting proxy_ready must not hang.
        resumeProxyReady(with: .failure(
            RealtimeTranscriptionError.connectionFailed("Connection lost while connecting")
        ))

        // A stopped or completed session must not restart, regardless of callback order.
        if endingSession {
            endBufferingSession()
            onConnectionStatusChanged?(.disconnected)
            return
        }

        if (webSocketTask?.response as? HTTPURLResponse)?.statusCode == 402 {
            Log.transcription.warning("Cloud RT: WS upgrade returned 402 — usage limit, not reconnecting")
            endBufferingSession()
            reportUsageLimit()
            return
        }

        // 1001 Going Away — proxy-initiated graceful close (8h cap or rolling restart).
        // Per ADR-0004: save partial transcript, show non-error UI, do NOT reconnect.
        if closeCode?.rawValue == 1001 {
            Log.transcription.info("Cloud RT: WS 1001 Going Away — session cap reached, not reconnecting")
            endBufferingSession()
            onConnectionStatusChanged?(.disconnected)
            // Signal upstream (AppDelegate / MeetingRecorderService) to flush partial transcript.
            // We reuse the existing segmentBoundary path: emit .endpoint so callers finalise.
            onSegmentBoundary?(.endpoint)
            return
        }

        lifecycleLock.lock()
        let attempt = reconnectAttempt + 1
        let withinLimit = attempt <= maxReconnectAttempts
        if withinLimit {
            reconnectAttempt = attempt
        }
        lifecycleLock.unlock()

        guard withinLimit else {
            Log.transcription.error("Cloud RT: Max reconnect attempts reached")
            endBufferingSession()
            onConnectionStatusChanged?(.failed("Connection lost after \(maxReconnectAttempts) attempts"))
            return
        }

        let delay = pow(2.0, Double(attempt)) // 2s, 4s, 8s

        Log.transcription.info("Cloud RT: Reconnecting (attempt \(attempt))...")
        onConnectionStatusChanged?(.reconnecting(attempt: attempt))

        lifecycleLock.lock()
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            // disconnect() cancels this task during the backoff sleep; bail before reconnecting.
            guard !Task.isCancelled else {
                Log.transcription.info("Cloud RT: Reconnect cancelled — session ended during backoff")
                return
            }

            do {
                try await self.connectWebSocket()
                self.resetReconnectAttempts()
                Log.transcription.info("Cloud RT: Reconnected successfully")
            } catch let error as RealtimeTranscriptionError {
                // ADR-0004: if WS upgrade returned 401, refresh the access token and retry once.
                if case .connectionFailed(let msg) = error, msg.contains("401") {
                    Log.transcription.info("Cloud RT: 401 on WS upgrade — refreshing session")
                    do {
                        try await AuthService.shared.refreshTokens()
                        try await self.connectWebSocket()
                        self.resetReconnectAttempts()
                        Log.transcription.info("Cloud RT: Reconnected after token refresh")
                    } catch {
                        Log.transcription.error("Cloud RT: Reconnect after token refresh failed - \(error.localizedDescription)")
                        self.endBufferingSession()
                        self.onError?(error)
                        self.onConnectionStatusChanged?(.failed("Session expired — please log in again"))
                    }
                } else {
                    Log.transcription.error("Cloud RT: Reconnect failed - \(error.localizedDescription)")
                    self.onError?(error)
                    self.handleDisconnect()
                }
            } catch {
                Log.transcription.error("Cloud RT: Reconnect failed - \(error.localizedDescription)")
                self.onError?(error)
                self.handleDisconnect()
            }
        }
        lifecycleLock.unlock()
    }

    static func makeConnectionConfig(
        languageHints: [String],
        strictLanguageHints: Bool,
        audioConfig: RealtimeAudioConfig,
        translationConfig: RealtimeTranslationConfig?,
        enableSpeakerDiarization: Bool
    ) -> [String: Any] {
        var config: [String: Any] = [
            "audio_format": audioConfig.audioFormat,
            "sample_rate": audioConfig.sampleRate,
            "num_channels": audioConfig.numChannels,
            "enable_speaker_diarization": enableSpeakerDiarization
        ]

        if !languageHints.isEmpty {
            config["language_hints"] = languageHints
            // Contract (see SettingsStorageProviderTests): any hints present are
            // treated as strict, regardless of `strictLanguageHints`.
            config["language_hints_strict"] = strictLanguageHints || !languageHints.isEmpty
        }

        if let translationPayload = makeTranslationPayload(from: translationConfig) {
            config["translation"] = translationPayload
        }

        return config
    }

    static func makeTranslationPayload(from config: RealtimeTranslationConfig?) -> [String: Any]? {
        guard let config else { return nil }
        switch config.mode {
        case let .twoWay(languageA, languageB):
            return [
                "type": "two_way",
                "language_a": languageA,
                "language_b": languageB
            ]
        case let .oneWay(targetLanguage):
            return [
                "type": "one_way",
                "target_language": targetLanguage
            ]
        }
    }

    private func segmentBoundary(from rawTokenText: String) -> RealtimeSegmentBoundary? {
        let normalized = rawTokenText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "<end>":
            return .endpoint
        case "<fin>":
            return .finalize
        default:
            return nil
        }
    }

    private func setFinalizeState(awaiting: Bool, finished: Bool) {
        finalizeStateLock.lock()
        awaitingFinalizeResponse = awaiting
        didReceiveFinishedSignal = finished
        if awaiting {
            lastRealtimeTokenAt = nil
            finalizeTokenCount = 0
            finalizeCharacterCount = 0
        } else {
            lastRealtimeTokenAt = nil
        }
        finalizeStateLock.unlock()
    }

    private func markTokenArrival(tokens: [RealtimeToken]) {
        finalizeStateLock.lock()
        if awaitingFinalizeResponse {
            lastRealtimeTokenAt = Date()
            finalizeTokenCount += tokens.count
            finalizeCharacterCount += tokens.reduce(0) { $0 + $1.text.count }
        }
        finalizeStateLock.unlock()
    }

    private func markFinishedSignalReceived() {
        lifecycleLock.lock()
        isSessionEnding = true
        lifecycleLock.unlock()
        finalizeStateLock.lock()
        if awaitingFinalizeResponse {
            didReceiveFinishedSignal = true
        }
        finalizeStateLock.unlock()
    }

    private func readFinalizeState() -> (
        finished: Bool,
        lastTokenAt: Date?,
        tokenCount: Int,
        characterCount: Int
    ) {
        finalizeStateLock.lock()
        let snapshot = (
            finished: didReceiveFinishedSignal,
            lastTokenAt: lastRealtimeTokenAt,
            tokenCount: finalizeTokenCount,
            characterCount: finalizeCharacterCount
        )
        finalizeStateLock.unlock()
        return snapshot
    }

    private func hasFinalizeQuietWindow(
        snapshot: (finished: Bool, lastTokenAt: Date?, tokenCount: Int, characterCount: Int),
        quietWindowSeconds: TimeInterval
    ) -> Bool {
        guard let lastTokenAt = snapshot.lastTokenAt else { return true }
        return Date().timeIntervalSince(lastTokenAt) >= quietWindowSeconds
    }

    private func makeFinalizeResult(
        profile: RealtimeFinalizeProfile,
        startedAt: Date,
        snapshot: (finished: Bool, lastTokenAt: Date?, tokenCount: Int, characterCount: Int),
        timedOut: Bool,
        quietWindowReached: Bool
    ) -> RealtimeFinalizeResult {
        RealtimeFinalizeResult(
            profileName: profile.name,
            didReceiveFinishedSignal: snapshot.finished,
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            tokensAfterFinalize: snapshot.tokenCount,
            charactersAfterFinalize: snapshot.characterCount,
            timedOut: timedOut,
            quietWindowReached: quietWindowReached
        )
    }

    private func logFinalizeResult(_ result: RealtimeFinalizeResult) {
        Log.transcription.info(
            "Cloud RT: Finalize result profile=\(result.profileName), finished=\(result.didReceiveFinishedSignal), timedOut=\(result.timedOut), quiet=\(result.quietWindowReached), durationMs=\(result.durationMs), tokensAfterFinalize=\(result.tokensAfterFinalize), charsAfterFinalize=\(result.charactersAfterFinalize)"
        )
    }
}

// MARK: - URLSessionWebSocketDelegate

extension CloudRealtimeService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lifecycleLock.lock()
        let metrics = currentConnectMetrics
        lifecycleLock.unlock()
        metrics?.end(.wsUpgrade)
        Log.transcription.info("Cloud RT: WebSocket opened, protocol: \(String(describing: `protocol`))")
    }

    nonisolated func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        Log.transcription.info("Cloud RT: WebSocket closed, code: \(closeCode.rawValue), reason: \(reasonStr)")
        // Delegate fires for server-initiated closes; drive reconnect logic from here.
        handleDisconnect(closeCode: closeCode)
    }
}
