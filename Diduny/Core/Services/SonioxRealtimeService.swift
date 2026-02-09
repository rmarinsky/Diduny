import Foundation
import os

@available(macOS 13.0, *)
final class SonioxRealtimeService: NSObject, @unchecked Sendable {
    private let wsURL = "wss://stt-rt.soniox.com/transcribe-websocket"
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    private var isConnected = false
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 3

    private var apiKey: String?
    private var languageHints: [String] = []

    var onTokensReceived: (([RealtimeToken]) -> Void)?
    var onError: ((Error) -> Void)?
    var onConnectionStatusChanged: ((RealtimeConnectionStatus) -> Void)?

    // MARK: - Connect

    func connect(apiKey: String, languageHints: [String] = ["uk"]) async throws {
        self.apiKey = apiKey
        self.languageHints = languageHints
        reconnectAttempt = 0
        try await connectWebSocket()
    }

    private func connectWebSocket() async throws {
        guard let apiKey else {
            throw RealtimeTranscriptionError.apiKeyMissing
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

        onConnectionStatusChanged?(.connecting)

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.urlSession = session

        guard let url = URL(string: wsURL) else {
            throw RealtimeTranscriptionError.connectionFailed("Invalid WebSocket URL")
        }

        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        // Send configuration
        let config: [String: Any] = [
            "api_key": apiKey,
            "model": "stt-rt-preview",
            "audio_format": "s16le",
            "sample_rate": 16000,
            "num_channels": 2,
            "language_hints": languageHints,
            "enable_speaker_diarization": true
        ]

        let configData = try JSONSerialization.data(withJSONObject: config)
        let configString = String(data: configData, encoding: .utf8) ?? "{}"

        NSLog("[Soniox RT] Sending config: %@", configString)
        try await task.send(.string(configString))
        NSLog("[Soniox RT] Config sent successfully, WebSocket connected")

        isConnected = true
        onConnectionStatusChanged?(.connected)

        startReceiveLoop()
        startPingLoop()
    }

    // MARK: - Send Audio Data

    private var audioBytesSent: Int = 0
    private var audioChunkCount: Int = 0

    func sendAudioData(_ data: Data) {
        guard isConnected, let task = webSocketTask else { return }

        audioBytesSent += data.count
        audioChunkCount += 1

        if audioChunkCount <= 5 || audioChunkCount % 100 == 0 {
            NSLog("[Soniox RT] Sending audio chunk #%d, size=%d, total=%d bytes", audioChunkCount, data.count, audioBytesSent)
        }

        task.send(.data(data)) { [weak self] error in
            if let error {
                Log.transcription.error("Soniox RT: Send error - \(error.localizedDescription)")
                self?.onError?(error)
            }
        }
    }

    // MARK: - Finalize

    func finalize() async {
        guard isConnected, let task = webSocketTask else { return }

        // Soniox requires an empty frame to signal end of audio and flush final tokens
        do {
            try await task.send(.data(Data()))
            Log.transcription.info("Soniox RT: Empty frame sent (finalize)")

            // Wait for server to send back final tokens and finished signal
            try? await Task.sleep(for: .seconds(3))
        } catch {
            Log.transcription.error("Soniox RT: Finalize error - \(error.localizedDescription)")
        }
    }

    // MARK: - Disconnect

    func disconnect() async {
        Log.transcription.info("Soniox RT: Disconnecting...")

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

        Log.transcription.info("Soniox RT: Disconnected")
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
                    NSLog("[Soniox RT] Receive error: %@", error.localizedDescription)
                    self.handleDisconnect()
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .string(text):
            NSLog("[Soniox RT] Received message: %@", String(text.prefix(300)))
            parseResponse(text)
        case let .data(data):
            NSLog("[Soniox RT] Received binary data: %d bytes", data.count)
            if let text = String(data: data, encoding: .utf8) {
                parseResponse(text)
            }
        @unknown default:
            break
        }
    }

    private func parseResponse(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            let response = try JSONDecoder().decode(SonioxRealtimeResponse.self, from: data)

            if response.finished == true {
                Log.transcription.info("Soniox RT: Received finished signal")
                return
            }

            guard let apiTokens = response.tokens, !apiTokens.isEmpty else { return }

            Log.transcription.info("Soniox RT: Received \(apiTokens.count) tokens, first: '\(apiTokens.first?.text ?? "")', is_final=\(apiTokens.first?.is_final ?? false)")

            let tokens = apiTokens.map { token in
                RealtimeToken(
                    text: token.text,
                    isFinal: token.is_final,
                    speaker: token.speaker,
                    startMs: token.start_ms ?? 0,
                    endMs: token.end_ms ?? 0
                )
            }

            onTokensReceived?(tokens)
        } catch {
            Log.transcription.error("Soniox RT: Parse error - \(error.localizedDescription), text: \(text.prefix(200))")
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
                        Log.transcription.warning("Soniox RT: Ping failed - \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Reconnect

    private func handleDisconnect() {
        guard isConnected else { return }
        isConnected = false

        guard reconnectAttempt < maxReconnectAttempts else {
            Log.transcription.error("Soniox RT: Max reconnect attempts reached")
            onConnectionStatusChanged?(.failed("Connection lost after \(maxReconnectAttempts) attempts"))
            return
        }

        reconnectAttempt += 1
        let delay = pow(2.0, Double(reconnectAttempt)) // 2s, 4s, 8s

        Log.transcription.info("Soniox RT: Reconnecting (attempt \(self.reconnectAttempt))...")
        onConnectionStatusChanged?(.reconnecting(attempt: reconnectAttempt))

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))

            do {
                try await self.connectWebSocket()
                self.reconnectAttempt = 0
                Log.transcription.info("Soniox RT: Reconnected successfully")
            } catch {
                Log.transcription.error("Soniox RT: Reconnect failed - \(error.localizedDescription)")
                self.onError?(error)
                self.handleDisconnect()
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

@available(macOS 13.0, *)
extension SonioxRealtimeService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Log.transcription.info("Soniox RT: WebSocket opened, protocol: \(String(describing: `protocol`))")
    }

    nonisolated func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        Log.transcription.info("Soniox RT: WebSocket closed, code: \(closeCode.rawValue), reason: \(reasonStr)")
    }
}
