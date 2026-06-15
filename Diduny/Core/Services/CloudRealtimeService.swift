import Foundation
import os

final class CloudRealtimeService: NSObject, @unchecked Sendable {
    private var wsURL: String {
        let settings = SettingsStorage.shared
        let proxyBase = settings.proxyBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        return "\(proxyBase)/api/v1/realtime"
    }
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var proxyReady = false

    private var isConnected = false
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 3

    private var languageHints: [String] = []
    private var strictLanguageHints = false
    private var audioConfig: RealtimeAudioConfig = .defaultPCM16kMono
    private var translationConfig: RealtimeTranslationConfig?
    private var enableSpeakerDiarization = true
    private let finalizeStateLock = NSLock()
    private var awaitingFinalizeResponse = false
    private var didReceiveFinishedSignal = false
    private var lastRealtimeTokenAt: Date?

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
        reconnectAttempt = 0
        try await connectWebSocket()
    }

    private func connectWebSocket() async throws {
        // Pre-check cached usage to avoid unnecessary connection attempt
        if let usage = await UsageService.shared.cachedUsage, !usage.isWhitelisted,
           let remaining = usage.remainingMs, remaining <= 0 {
            throw RealtimeTranscriptionError.usageLimitExceeded(
                usedHours: usage.usedHours, limitHours: usage.limitHours ?? 5
            )
        }

        // Clean up any existing connection before reconnecting
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        audioBytesSent = 0
        audioChunkCount = 0
        proxyReady = false

        onConnectionStatusChanged?(.connecting)

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.urlSession = session

        var wsURLString = wsURL

        // Pass auth token as query param (WebSocket headers are limited)
        if let accessToken = await AuthService.shared.getAccessToken() {
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
        task.resume()

        var config: [String: Any] = [
            "audio_format": audioConfig.audioFormat,
            "sample_rate": audioConfig.sampleRate,
            "num_channels": audioConfig.numChannels,
            "enable_speaker_diarization": enableSpeakerDiarization
        ]

        if !languageHints.isEmpty {
            config["language_hints"] = languageHints
        }

        if let translationPayload = makeTranslationPayload(from: translationConfig) {
            config["translation"] = translationPayload
        }

        let configData = try JSONSerialization.data(withJSONObject: config)
        let configString = String(data: configData, encoding: .utf8) ?? "{}"

        NSLog("[Cloud RT] Sending config: %@", configString)
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
        NSLog("[Cloud RT] Config sent successfully, WebSocket connected")

        isConnected = true

        startReceiveLoop()
        startPingLoop()

        // Wait for proxy_ready before marking connected
        let deadline = Date().addingTimeInterval(10)
        while !proxyReady && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard proxyReady else {
            throw RealtimeTranscriptionError.connectionFailed("Proxy did not send ready signal")
        }

        onConnectionStatusChanged?(.connected)
    }

    // MARK: - Send Audio Data

    private var audioBytesSent: Int = 0
    private var audioChunkCount: Int = 0

    func sendAudioData(_ data: Data) {
        guard isConnected, let task = webSocketTask else { return }
        guard !data.isEmpty else { return }

        audioBytesSent += data.count
        audioChunkCount += 1

        if audioChunkCount <= 5 || audioChunkCount % 100 == 0 {
            NSLog(
                "[Cloud RT] Sending audio chunk #%d, size=%d, total=%d bytes",
                audioChunkCount,
                data.count,
                audioBytesSent
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

    func finalize() async -> Bool {
        guard isConnected, let task = webSocketTask else { return false }

        setFinalizeState(awaiting: true, finished: false)

        do {
            let finalizePayloadData = try JSONSerialization.data(withJSONObject: ["type": "finalize"])
            if let finalizePayload = String(data: finalizePayloadData, encoding: .utf8) {
                try await task.send(.string(finalizePayload))
                Log.transcription.info("Cloud RT: Finalize control message sent")
                try? await Task.sleep(for: .milliseconds(350))
            }

            // Empty frame ends the stream and flushes pending final tokens.
            try await task.send(.data(Data()))
            Log.transcription.info("Cloud RT: Empty frame sent (finalize)")

            // Wait for explicit finished signal and a short quiet window for final tokens.
            let timeoutSeconds = 5.0
            let quietWindowSeconds = 0.35
            let deadline = Date().addingTimeInterval(timeoutSeconds)

            while Date() < deadline {
                let snapshot = readFinalizeState()
                let hasQuietWindow: Bool = {
                    guard let lastTokenAt = snapshot.lastTokenAt else { return true }
                    return Date().timeIntervalSince(lastTokenAt) >= quietWindowSeconds
                }()

                if snapshot.finished && hasQuietWindow {
                    setFinalizeState(awaiting: false, finished: false)
                    return true
                }

                try? await Task.sleep(for: .milliseconds(50))
            }

            let timedOutSnapshot = readFinalizeState()
            setFinalizeState(awaiting: false, finished: false)
            if !timedOutSnapshot.finished {
                Log.transcription.warning("Cloud RT: Finalize timeout — finished signal was not received")
            } else {
                Log.transcription.warning("Cloud RT: Finalize timeout — finished received but quiet window not reached")
            }
            return timedOutSnapshot.finished
        } catch {
            Log.transcription.error("Cloud RT: Finalize error - \(error.localizedDescription)")
            setFinalizeState(awaiting: false, finished: false)
            return false
        }
    }

    // MARK: - Disconnect

    func disconnect() async {
        Log.transcription.info("Cloud RT: Disconnecting...")

        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        if let task = webSocketTask {
            task.cancel(with: .normalClosure, reason: nil)
        }

        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        onConnectionStatusChanged?(.disconnected)

        Log.transcription.info("Cloud RT: Disconnected")
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
            proxyReady = true
            NSLog("[Cloud RT] Received proxy_ready signal")
            return
        }

        // Handle proxy error frames
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorMsg = json["error"] as? String,
           json["tokens"] == nil {
            let error = RealtimeTranscriptionError.connectionFailed(errorMsg)
            Log.transcription.error("Cloud RT: Proxy error - \(errorMsg)")
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
                            markTokenArrival()
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
                    markTokenArrival()
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
            limitHours: usage?.limitHours ?? 5
        )
    }

    /// Called when the receive loop exits due to an error or a server-initiated close.
    ///
    /// ADR-0004 edge cases handled here:
    /// - `1001 Going Away` (proxy 8-hour cap or rolling restart): treat as graceful session end,
    ///   save partial transcript, show non-error UI, do NOT auto-reconnect.
    /// - `401` from proxy on reconnect: refresh Supabase session silently, retry once.
    ///   Never loop — if the refresh fails the user is prompted to re-login.
    private func handleDisconnect(closeCode: URLSessionWebSocketTask.CloseCode? = nil) {
        guard isConnected else { return }
        isConnected = false

        // A refused WS upgrade (HTTP 402 usage limit) lands here via the receive
        // loop with no close code. Reconnecting is futile — the server will keep
        // refusing — and would surface a generic "Connection lost" instead of the
        // real reason. Detect it synchronously to stop the reconnect, then surface
        // the typed usage error with the best numbers we have.
        if (webSocketTask?.response as? HTTPURLResponse)?.statusCode == 402 {
            Log.transcription.warning("Cloud RT: WS upgrade returned 402 — usage limit, not reconnecting")
            Task { [weak self] in
                guard let self else { return }
                let usage = await UsageService.shared.cachedUsage
                await UsageService.shared.refresh()
                self.onError?(RealtimeTranscriptionError.usageLimitExceeded(
                    usedHours: usage?.usedHours ?? 0,
                    limitHours: usage?.limitHours ?? 5
                ))
                self.onConnectionStatusChanged?(.failed("Cloud usage limit reached"))
            }
            return
        }

        // 1001 Going Away — proxy-initiated graceful close (8h cap or rolling restart).
        // Per ADR-0004: save partial transcript, show non-error UI, do NOT reconnect.
        if closeCode?.rawValue == 1001 {
            Log.transcription.info("Cloud RT: WS 1001 Going Away — session cap reached, not reconnecting")
            onConnectionStatusChanged?(.disconnected)
            // Signal upstream (AppDelegate / MeetingRecorderService) to flush partial transcript.
            // We reuse the existing segmentBoundary path: emit .endpoint so callers finalise.
            onSegmentBoundary?(.endpoint)
            return
        }

        guard reconnectAttempt < maxReconnectAttempts else {
            Log.transcription.error("Cloud RT: Max reconnect attempts reached")
            onConnectionStatusChanged?(.failed("Connection lost after \(maxReconnectAttempts) attempts"))
            return
        }

        reconnectAttempt += 1
        let delay = pow(2.0, Double(reconnectAttempt)) // 2s, 4s, 8s

        Log.transcription.info("Cloud RT: Reconnecting (attempt \(self.reconnectAttempt))...")
        onConnectionStatusChanged?(.reconnecting(attempt: reconnectAttempt))

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))

            do {
                try await self.connectWebSocket()
                self.reconnectAttempt = 0
                Log.transcription.info("Cloud RT: Reconnected successfully")
            } catch let error as RealtimeTranscriptionError {
                // ADR-0004: if WS upgrade returned 401, refresh Supabase token and retry once.
                if case .connectionFailed(let msg) = error, msg.contains("401") {
                    Log.transcription.info("Cloud RT: 401 on WS upgrade — refreshing Supabase session")
                    do {
                        try await AuthService.shared.refreshTokens()
                        try await self.connectWebSocket()
                        self.reconnectAttempt = 0
                        Log.transcription.info("Cloud RT: Reconnected after token refresh")
                    } catch {
                        Log.transcription.error("Cloud RT: Reconnect after token refresh failed - \(error.localizedDescription)")
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
    }

    private func makeTranslationPayload(from config: RealtimeTranslationConfig?) -> [String: Any]? {
        guard let config else { return nil }
        switch config.mode {
        case let .twoWay(languageA, languageB):
            return [
                "type": "two_way",
                "language_a": languageA,
                "language_b": languageB
            ]
        case let .oneWay(sourceLanguage, targetLanguage):
            return [
                "type": "one_way",
                "source_language": sourceLanguage,
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
        if !awaiting {
            lastRealtimeTokenAt = nil
        }
        finalizeStateLock.unlock()
    }

    private func markTokenArrival() {
        finalizeStateLock.lock()
        if awaitingFinalizeResponse {
            lastRealtimeTokenAt = Date()
        }
        finalizeStateLock.unlock()
    }

    private func markFinishedSignalReceived() {
        finalizeStateLock.lock()
        if awaitingFinalizeResponse {
            didReceiveFinishedSignal = true
        }
        finalizeStateLock.unlock()
    }

    private func readFinalizeState() -> (finished: Bool, lastTokenAt: Date?) {
        finalizeStateLock.lock()
        let snapshot = (finished: didReceiveFinishedSignal, lastTokenAt: lastRealtimeTokenAt)
        finalizeStateLock.unlock()
        return snapshot
    }
}

// MARK: - URLSessionWebSocketDelegate

extension CloudRealtimeService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
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
