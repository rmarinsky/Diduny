@testable import Diduny
import XCTest

/// In-memory WebSocket: tests push server frames, inspect sent frames and close calls.
final class FakeElevenLabsTransport: ElevenLabsRealtimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var dropped = false
    private var sentFrames: [String] = []
    private var closes = 0

    var sent: [String] { lock.withLock { sentFrames } }
    var closeCount: Int { lock.withLock { closes } }

    func push(_ frame: String) {
        let waiter: CheckedContinuation<String, Error>? = lock.withLock {
            if waiters.isEmpty { inbox.append(frame); return nil }
            return waiters.removeFirst()
        }
        waiter?.resume(returning: frame)
    }

    func drop() {
        let pending: [CheckedContinuation<String, Error>] = lock.withLock {
            dropped = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume(throwing: URLError(.networkConnectionLost)) }
    }

    func send(_ text: String) async throws { lock.withLock { sentFrames.append(text) } }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<String, Error>? = lock.withLock {
                if !inbox.isEmpty { return .success(inbox.removeFirst()) }
                if dropped { return .failure(URLError(.networkConnectionLost)) }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func close() { lock.withLock { closes += 1 } }

    var sentPayloads: [[String: Any]] {
        sent.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}

final class ElevenLabsRealtimeServiceTests: XCTestCase {
    private let sentinel = "sk_TEST_SENTINEL_0123456789"
    private let started = #"{"message_type":"session_started","session_id":"s1","config":{}}"#
    private var transports: [FakeElevenLabsTransport] = []

    /// Keepalive parks on this ticker, so no test depends on wall-clock intervals.
    private let ticker = ManualTicker()

    private func makeService(
        keepalive: TimeInterval = 5,
        periodicCommit: TimeInterval? = nil,
        reconnectOnDrop: Bool = false
    ) -> ElevenLabsRealtimeService {
        let ticker = ticker
        return ElevenLabsRealtimeService(
            apiKey: sentinel,
            keepaliveInterval: keepalive,
            maxReconnects: 2,
            periodicCommitInterval: periodicCommit,
            reconnectOnDrop: reconnectOnDrop,
            sleep: { await ticker.sleep($0) }
        ) { [unowned self] _ in
            let transport = FakeElevenLabsTransport()
            transport.push(started)
            transports.append(transport)
            return transport
        }
    }

    func testRequestShapeUsesHeaderAuthAndQuery() {
        let request = ElevenLabsRealtimeService.makeRequest(
            apiKey: sentinel, languageHints: ["uk", "en"], sampleRate: 16000, commitStrategy: .vad
        )
        let url = request.url!.absoluteString
        XCTAssertTrue(url.hasPrefix("wss://api.elevenlabs.io/v1/speech-to-text/realtime?"))
        XCTAssertTrue(url.contains("model_id=scribe_v2_realtime"))
        XCTAssertTrue(url.contains("audio_format=pcm_16000"))
        XCTAssertTrue(url.contains("commit_strategy=vad"))
        XCTAssertTrue(url.contains("language_code=uk"))
        XCTAssertTrue(url.contains("secondary_languages=en"))
        XCTAssertFalse(url.contains("include_timestamps"))
        XCTAssertFalse(url.contains(sentinel))
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), sentinel)
    }

    func testAutoLanguageOmitsLanguageCode() {
        let request = ElevenLabsRealtimeService.makeRequest(
            apiKey: sentinel, languageHints: ["auto"], sampleRate: 16000, commitStrategy: .manual
        )
        XCTAssertFalse(request.url!.absoluteString.contains("language_code"))
    }

    func testAudioChunkShape() async throws {
        let service = makeService()
        try await service.connect()
        service.sendAudioData(Data([3, 4]))
        await waitUntil { transports.first?.sent.isEmpty == false }
        let payload = try XCTUnwrap(transports.first?.sentPayloads.first)
        XCTAssertEqual(payload["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(payload["audio_base_64"] as? String, Data([3, 4]).base64EncodedString())
        XCTAssertEqual(payload["commit"] as? Bool, false)
        XCTAssertEqual(payload["sample_rate"] as? Int, 16000)
        XCTAssertNil(payload["previous_text"])
        await service.disconnect()
    }

    func testPartialReplacesAndCommitAppendsThenFinalize() async throws {
        let service = makeService()
        var tokens: [RealtimeToken] = []
        var boundaries: [RealtimeSegmentBoundary] = []
        service.onTokensReceived = { tokens += $0 }
        service.onSegmentBoundary = { boundaries.append($0) }
        try await service.connect()
        let socket = try XCTUnwrap(transports.first)

        socket.push(#"{"message_type":"partial_transcript","text":"hel"}"#)
        socket.push(#"{"message_type":"partial_transcript","text":""}"#)
        socket.push(#"{"message_type":"partial_transcript","text":"hello"}"#)
        socket.push(#"{"message_type":"committed_transcript","text":"Hello."}"#)
        socket.push(#"{"message_type":"committed_transcript_with_timestamps","text":"Hello.","words":[]}"#)
        socket.push(#"{"message_type":"something_new"}"#)
        await waitUntil { tokens.count == 3 && boundaries.count == 1 }

        XCTAssertEqual(tokens.map(\.text), ["hel", "hello", "Hello."])
        XCTAssertEqual(tokens.map(\.isFinal), [false, false, true])
        XCTAssertEqual(boundaries.count, 1)

        let finalizeTask = Task { await service.finalize(profile: .safe) }
        await waitUntil { socket.sentPayloads.contains { $0["commit"] as? Bool == true } }
        socket.push(#"{"message_type":"committed_transcript","text":"World"}"#)
        let result = await finalizeTask.value

        XCTAssertTrue(result.didReceiveFinishedSignal)
        XCTAssertEqual(result.tokensAfterFinalize, 1)
        XCTAssertEqual(tokens.last?.text, " World")
        if case .finalize = boundaries.last {} else { XCTFail("expected finalize boundary") }
        let commits = socket.sentPayloads.filter { $0["commit"] as? Bool == true }
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?["audio_base_64"] as? String, "")

        await service.disconnect()
        XCTAssertEqual(socket.closeCount, 1)
    }

    func testFinalizeWithoutConnectionIsSkipped() async {
        let result = await makeService().finalize(profile: .dictationFast)
        XCTAssertEqual(result, .skipped)
    }

    func testKeepaliveSendsSilenceWhileIdleAndStopsAfterClose() async throws {
        let service = makeService(keepalive: 5)
        try await service.connect()
        let socket = try XCTUnwrap(transports.first)
        await waitUntil { ticker.waiting == 1 }
        XCTAssertEqual(ticker.intervals, [5])

        ticker.tick()
        await waitUntil { socket.sent.count == 1 }
        let payload = try XCTUnwrap(socket.sentPayloads.first)
        XCTAssertEqual(payload["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(payload["commit"] as? Bool, false)
        XCTAssertEqual(payload["sample_rate"] as? Int, 16000)
        // 100 ms of 16 kHz 16-bit silence.
        XCTAssertEqual(payload["audio_base_64"] as? String, Data(count: 3200).base64EncodedString())

        // Audio sent since the last tick: no keepalive on the next one.
        await waitUntil { ticker.waiting == 1 }
        service.sendAudioData(Data([9]))
        await waitUntil { socket.sent.count == 2 }
        ticker.tick()
        await waitUntil { ticker.waiting == 1 }
        XCTAssertEqual(socket.sent.count, 2)

        await service.disconnect()
        let countAfterClose = socket.sent.count
        let sleepsAfterClose = ticker.intervals.count
        ticker.tick()
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertEqual(socket.sent.count, countAfterClose)
        XCTAssertEqual(ticker.intervals.count, sleepsAfterClose, "keepalive loop ended after close")
    }

    func testEachServerErrorEndsSessionWithMappedErrorAndNoReconnect() async throws {
        let cases: [(String, ElevenLabsError)] = [
            ("auth_error", .invalidKey),
            ("quota_exceeded", .quotaExceeded),
            ("unaccepted_terms", .termsNotAccepted),
            ("rate_limited", .rateLimited),
            ("commit_throttled", .rateLimited),
            ("queue_overflow", .rateLimited),
            ("resource_exhausted", .rateLimited),
            ("input_error", .sessionEnded(code: "input_error")),
            ("invalid_request", .sessionEnded(code: "invalid_request")),
            ("chunk_size_exceeded", .sessionEnded(code: "chunk_size_exceeded")),
            ("insufficient_audio_activity", .sessionEnded(code: "insufficient_audio_activity")),
            ("transcriber_error", .sessionEnded(code: "transcriber_error")),
            ("error", .sessionEnded(code: "error"))
        ]
        for (type, expected) in cases {
            transports = []
            let service = makeService()
            var errors: [Error] = []
            var statuses: [RealtimeConnectionStatus] = []
            service.setConnectionHandlers(
                onError: { errors.append($0) },
                onConnectionStatusChanged: { statuses.append($0) }
            )
            try await service.connect()
            transports[0].push(#"{"message_type":"\#(type)","error":"details"}"#)
            await waitUntil {
                if case .failed = statuses.last { return !errors.isEmpty }
                return false
            }
            XCTAssertEqual(errors.first as? ElevenLabsError, expected, type)
            XCTAssertEqual(transports.count, 1, "no reconnect for \(type)")
            XCTAssertEqual(transports[0].closeCount, 1)
            if case .failed = statuses.last {} else { XCTFail("expected failed status for \(type)") }
            XCTAssertFalse(errors.first?.localizedDescription.contains(sentinel) ?? true)
            await service.disconnect()
        }
    }

    func testSocketDropKeepsCommittedTextAndDoesNotReconnect() async throws {
        let service = makeService()
        var tokens: [RealtimeToken] = []
        var errors: [Error] = []
        service.onTokensReceived = { tokens += $0 }
        service.setConnectionHandlers(onError: { errors.append($0) }, onConnectionStatusChanged: nil)
        try await service.connect()
        transports[0].push(#"{"message_type":"committed_transcript","text":"kept"}"#)
        await waitUntil { tokens.count == 1 }
        transports[0].drop()
        await waitUntil { !errors.isEmpty }
        XCTAssertEqual(errors.first as? ElevenLabsError, .network)
        XCTAssertEqual(tokens.map(\.text), ["kept"])
        XCTAssertEqual(transports.count, 1)
    }

    func testSessionLimitReconnectsWithPreviousTextOnFirstChunkOnly() async throws {
        let service = makeService()
        var tokens: [RealtimeToken] = []
        service.onTokensReceived = { tokens += $0 }
        try await service.connect()
        transports[0].push(#"{"message_type":"committed_transcript","text":"First part of the meeting."}"#)
        transports[0].push(#"{"message_type":"session_time_limit_exceeded","error":"limit"}"#)
        await waitUntil { transports.count == 2 && tokens.count == 1 }
        XCTAssertEqual(transports.count, 2)

        service.sendAudioData(Data([1]))
        service.sendAudioData(Data([2]))
        transports[1].push(#"{"message_type":"committed_transcript","text":"Second."}"#)
        await waitUntil { tokens.count == 2 && transports[1].sent.count >= 2 }

        let payloads = transports[1].sentPayloads
        XCTAssertEqual(payloads.first?["previous_text"] as? String, "First part of the meeting.")
        XCTAssertNil(payloads.dropFirst().first?["previous_text"])
        XCTAssertEqual(tokens.map(\.text), ["First part of the meeting.", " Second."])
        await service.disconnect()
    }

    func testRepeatedSessionLimitsKeepReconnecting() async throws {
        let service = makeService() // maxReconnects: 2
        var errors: [Error] = []
        service.setConnectionHandlers(onError: { errors.append($0) }, onConnectionStatusChanged: nil)
        try await service.connect()
        for index in 0 ..< 5 {
            transports[index].push(#"{"message_type":"session_time_limit_exceeded","error":"limit"}"#)
            await waitUntil { transports.count == index + 2 }
        }
        XCTAssertEqual(transports.count, 6)
        XCTAssertTrue(errors.isEmpty)
        await service.disconnect()
    }

    func testConsecutiveFailedReconnectsAreBounded() async throws {
        var made: [FakeElevenLabsTransport] = []
        let service = ElevenLabsRealtimeService(apiKey: sentinel, maxReconnects: 2) { _ in
            let transport = FakeElevenLabsTransport()
            // First socket opens; every later one is refused.
            transport.push(made.isEmpty ? self.started : #"{"message_type":"rate_limited","error":"x"}"#)
            made.append(transport)
            return transport
        }
        var errors: [Error] = []
        service.setConnectionHandlers(onError: { errors.append($0) }, onConnectionStatusChanged: nil)
        try await service.connect()
        made[0].push(#"{"message_type":"session_time_limit_exceeded","error":"limit"}"#)
        await waitUntil { !errors.isEmpty }
        XCTAssertEqual(made.count, 2, "reconnect failed, then the session ends")
        XCTAssertEqual(errors.first as? ElevenLabsError, .sessionEnded(code: "session_time_limit_exceeded"))
    }

    func testFinalizeIgnoresAnswerToEarlierPeriodicCommit() async throws {
        let service = makeService(keepalive: 5, periodicCommit: 5)
        var tokens: [RealtimeToken] = []
        service.onTokensReceived = { tokens += $0 }
        try await service.connect()
        let socket = try XCTUnwrap(transports.first)
        let commits = { socket.sentPayloads.filter { $0["commit"] as? Bool == true }.count }

        socket.push(#"{"message_type":"partial_transcript","text":"early"}"#)
        await waitUntil { tokens.count == 1 }
        await waitUntil { ticker.waiting == 1 }
        ticker.tick()
        await waitUntil { commits() == 1 }

        let finalizeTask = Task { await service.finalize(profile: .safe) }
        await waitUntil { commits() == 2 }
        socket.push(#"{"message_type":"committed_transcript","text":"early"}"#)
        await waitUntil { tokens.count == 2 }
        for _ in 0 ..< 20 { await Task.yield() }
        socket.push(#"{"message_type":"committed_transcript","text":"last words"}"#)
        let result = await finalizeTask.value

        XCTAssertTrue(result.didReceiveFinishedSignal)
        XCTAssertEqual(tokens.last?.text, " last words")
        await service.disconnect()
    }

    func testConnectFailsWithMappedErrorWhenFirstMessageIsError() async {
        let service = ElevenLabsRealtimeService(apiKey: sentinel) { _ in
            let transport = FakeElevenLabsTransport()
            transport.push(#"{"message_type":"auth_error","error":"bad key"}"#)
            return transport
        }
        do {
            try await service.connect()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ElevenLabsError, .invalidKey)
        }
    }

    func testRealtimeModelIsDeclared() throws {
        let model = try XCTUnwrap(ElevenLabsProvider().models.first { $0.id == "scribe_v2_realtime" })
        XCTAssertNil(model.capabilities.batch)
        XCTAssertEqual(model.capabilities.realtime?.idleTimeoutSeconds, 15)
        XCTAssertEqual(model.capabilities.realtime?.diarization, false)
        XCTAssertNil(model.capabilities.realtime?.maxSessionSeconds)
    }

    func testPeriodicCommitOnlyWhenPartialIsPending() async throws {
        let service = makeService(keepalive: 5, periodicCommit: 10)
        var tokens: [RealtimeToken] = []
        service.onTokensReceived = { tokens += $0 }
        try await service.connect()
        let socket = try XCTUnwrap(transports.first)
        let commits = { socket.sentPayloads.filter { $0["commit"] as? Bool == true }.count }

        // Nothing pending: two ticks reach the interval but send no commit.
        for _ in 0 ..< 2 {
            await waitUntil { ticker.waiting == 1 }
            ticker.tick()
        }
        await waitUntil { ticker.waiting == 1 }
        XCTAssertEqual(commits(), 0)

        socket.push(#"{"message_type":"partial_transcript","text":"still talking"}"#)
        await waitUntil { tokens.count == 1 }
        for _ in 0 ..< 2 {
            await waitUntil { ticker.waiting == 1 }
            ticker.tick()
        }
        await waitUntil { commits() == 1 }

        // The commit answer clears the pending flag: no second commit.
        socket.push(#"{"message_type":"committed_transcript","text":"still talking"}"#)
        await waitUntil { tokens.count == 2 }
        for _ in 0 ..< 2 {
            await waitUntil { ticker.waiting == 1 }
            ticker.tick()
        }
        await waitUntil { ticker.waiting == 1 }
        XCTAssertEqual(commits(), 1)
        await service.disconnect()
    }

    func testDropReconnectsWhenEnabledAndKeepsCommittedText() async throws {
        let service = makeService(reconnectOnDrop: true)
        var tokens: [RealtimeToken] = []
        var errors: [Error] = []
        service.onTokensReceived = { tokens += $0 }
        service.setConnectionHandlers(onError: { errors.append($0) }, onConnectionStatusChanged: nil)
        try await service.connect()
        transports[0].push(#"{"message_type":"committed_transcript","text":"kept"}"#)
        await waitUntil { tokens.count == 1 }
        transports[0].drop()
        await waitUntil { transports.count == 2 }

        service.sendAudioData(Data([1]))
        await waitUntil { !transports[1].sent.isEmpty }
        XCTAssertEqual(transports[1].sentPayloads.first?["previous_text"] as? String, "kept")
        XCTAssertTrue(errors.isEmpty)
        await service.disconnect()
    }

    func testConformsToRealtimeProtocol() {
        let service: RealtimeTranscriptionProtocol = makeService()
        XCTAssertNotNil(service)
    }
}
