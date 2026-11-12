@testable import Diduny
import XCTest

final class ElevenLabsBatchServiceTests: XCTestCase {
    private let sentinel = "sk_TEST_SENTINEL_0123456789"
    private var audioURL: URL!

    override func setUp() {
        StubURLProtocol.reset()
        audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("el-\(UUID().uuidString).wav")
        try? Data([1, 2, 3, 4]).write(to: audioURL)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: audioURL)
    }

    private final class Counter { var value = 0 }

    private func makeService(sleeps: Counter? = nil) -> ElevenLabsBatchService {
        ElevenLabsBatchService(
            session: StubURLProtocol.session(),
            apiKey: { [sentinel] in sentinel },
            sleep: { _ in sleeps?.value += 1 }
        )
    }

    private let helloWorld = """
    {"language_code":"eng","language_probability":0.98,"text":"Hello world!","transcription_id":"tr_1",
     "words":[{"text":"Hello","type":"word","start":0,"end":0.5,"speaker_id":"speaker_0","logprob":-0.1},
              {"text":" ","type":"spacing","start":0.5,"end":0.5,"speaker_id":"speaker_0"},
              {"text":"(laughs)","type":"audio_event","start":0.5,"end":0.7,"speaker_id":"speaker_0"},
              {"text":"world!","type":"word","start":null,"end":null,"speaker_id":null}]}
    """

    func testRequestShape() async throws {
        StubURLProtocol.responses = [(200, helloWorld)]
        _ = try await makeService().transcribe(audioURL: audioURL, languageCode: "uk", diarize: true)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), sentinel)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
    }

    func testMultipartBodyFields() throws {
        let url = try ElevenLabsBatchService.makeMultipartBody(
            fields: [("model_id", "scribe_v2"), ("language_code", "uk")], audioURL: audioURL, boundary: "B"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let body = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model_id\"\r\n\r\nscribe_v2\r\n"))
        XCTAssertTrue(body.contains("name=\"language_code\"\r\n\r\nuk\r\n"))
        XCTAssertTrue(body.contains("name=\"file\"; filename="))
        XCTAssertTrue(body.hasSuffix("--B--\r\n"))
        XCTAssertFalse(body.contains("enable_logging"))
    }

    func testResponseMapping() throws {
        let result = try ElevenLabsBatchService.parse(Data(helloWorld.utf8), diarize: false)
        XCTAssertEqual(result.transcript.text, "Hello world!")
        XCTAssertEqual(result.transcriptionID, "tr_1")
        XCTAssertEqual(result.languageCode, "en")
        XCTAssertFalse(result.transcript.segments.map(\.text).joined().contains("laughs"))
    }

    func testDiarizedMappingLabelsSpeakers() throws {
        let json = """
        {"language_code":"en","text":"Hi there","words":[
          {"text":"Hi","type":"word","start":0,"end":0.3,"speaker_id":"speaker_0"},
          {"text":" ","type":"spacing","start":0.3,"end":0.3,"speaker_id":"speaker_0"},
          {"text":"there","type":"word","start":5,"end":5.3,"speaker_id":"speaker_1"}]}
        """
        let result = try ElevenLabsBatchService.parse(Data(json.utf8), diarize: true)
        XCTAssertNil(result.transcriptionID)
        XCTAssertTrue(result.transcript.text.contains("Hi"))
        XCTAssertTrue(result.transcript.text.contains("there"))
    }

    func testMultichannelAndEmptyAndMalformed() throws {
        let multi = #"{"transcripts":[{"language_code":"en","text":"a","words":[]},{"text":"b","words":[]}],"transcription_id":"t"}"#
        XCTAssertEqual(try ElevenLabsBatchService.parse(Data(multi.utf8), diarize: false).transcript.text, "a\nb")
        let empty = #"{"language_code":"en","text":"","words":[]}"#
        XCTAssertEqual(try ElevenLabsBatchService.parse(Data(empty.utf8), diarize: false).transcript.text, "")
        XCTAssertThrowsError(try ElevenLabsBatchService.parse(Data("not json".utf8), diarize: false)) {
            XCTAssertEqual($0 as? ElevenLabsError, .invalidResponse)
        }
    }

    func testRetriesOnceOn429ThenSucceeds() async throws {
        let sleeps = Counter()
        StubURLProtocol.responses = [(429, "{}"), (200, helloWorld)]
        let result = try await makeService(sleeps: sleeps).transcribe(audioURL: audioURL)
        XCTAssertEqual(result.transcriptionID, "tr_1")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertEqual(sleeps.value, 1)
    }

    func testTwo429sGiveRateLimitedAfterTwoRequests() async {
        StubURLProtocol.responses = [(429, "{}"), (429, "{}")]
        await assertThrows(.rateLimited)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testAuthAndQuotaAreNotRetried() async {
        for (status, expected) in [(401, ElevenLabsError.invalidKey), (402, .quotaExceeded), (403, .missingPermission)] {
            StubURLProtocol.reset()
            StubURLProtocol.responses = [(status, "{}")]
            await assertThrows(expected)
            XCTAssertEqual(StubURLProtocol.requests.count, 1)
        }
    }

    func testNetworkFailureMapsToNetwork() async {
        StubURLProtocol.failWith = URLError(.notConnectedToInternet)
        await assertThrows(.network)
    }

    private func assertThrows(_ expected: ElevenLabsError, line: UInt = #line) async {
        do {
            _ = try await makeService().transcribe(audioURL: audioURL)
            XCTFail("expected error", line: line)
        } catch {
            XCTAssertEqual(error as? ElevenLabsError, expected, line: line)
        }
    }

    // MARK: - DELETE

    func testDeleteRequestShapeAndMapping() async throws {
        let deleter = ElevenLabsTranscriptDeleter(session: StubURLProtocol.session())
        StubURLProtocol.responses = [(200, "{}"), (404, "{}"), (401, "{}"), (403, "{}"), (500, "{}"), (429, "{}")]
        var results: [RemoteDeleteResult] = []
        for _ in 0 ..< 6 { results.append(await deleter.deleteTranscript(remoteID: "tr_1", apiKey: sentinel)) }
        XCTAssertEqual(results, [.deleted, .notFound, .unauthorized, .unauthorized, .retryLater, .retryLater])
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text/transcripts/tr_1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), sentinel)
    }
}

final class ElevenLabsErrorMappingTests: XCTestCase {
    private func map(_ status: Int, _ body: String) -> ElevenLabsError {
        ElevenLabsError.from(httpStatus: status, body: Data(body.utf8))
    }

    func testErrorShapes() {
        XCTAssertEqual(map(401, #"{"detail":{"type":"authentication_error","code":"invalid_api_key","message":"x"}}"#), .invalidKey)
        XCTAssertEqual(map(401, #"{"detail":{"status":"invalid_api_key","message":"x"}}"#), .invalidKey)
        XCTAssertEqual(map(400, #"{"detail":{"status":"quota_exceeded","message":"x"}}"#), .quotaExceeded)
        XCTAssertEqual(map(402, #"{"detail":{"code":"insufficient_credits"}}"#), .quotaExceeded)
        XCTAssertEqual(map(403, #"{"detail":{"code":"insufficient_permissions"}}"#), .missingPermission)
        XCTAssertEqual(map(403, #"{"detail":{"code":"model_access_denied"}}"#), .planOrModelNotAvailable)
        XCTAssertEqual(map(429, #"{"detail":{"code":"concurrent_limit_exceeded"}}"#), .rateLimited)
        XCTAssertEqual(map(422, #"{"detail":[{"loc":["body"],"msg":"m","type":"value_error"}]}"#), .unknown(status: 422, requestID: nil))
        XCTAssertEqual(map(500, #"{"detail":{"code":"internal_error","request_id":"req_9"}}"#), .unknown(status: 500, requestID: "req_9"))
        XCTAssertEqual(map(403, #"{"detail":{"status":"unaccepted_terms","message":"Accept the terms"}}"#), .termsNotAccepted)
        if case .unusualActivity = map(401, #"{"detail":{"status":"detected_unusual_activity","message":"Unusual activity detected. Free Tier usage disabled."}}"#) {} else {
            XCTFail("unusual activity not mapped")
        }
    }

    func testMessagesHaveNoKeyAndAreNonEmpty() {
        let all: [ElevenLabsError] = [.invalidKey, .missingPermission, .planOrModelNotAvailable, .termsNotAccepted,
                                      .quotaExceeded, .rateLimited, .network, .invalidResponse,
                                      .unknown(status: 500, requestID: "r")]
        for error in all {
            let message = error.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("sk_TEST_SENTINEL"))
        }
    }
}

final class ElevenLabsAccountServiceTests: XCTestCase {
    private let sentinel = "sk_TEST_SENTINEL_0123456789"

    override func setUp() { StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset() }

    func testTestConnectionOKWithPlanAndUsage() async throws {
        let body = #"{"tier":"starter","character_count":1000,"character_limit":10000,"next_character_count_reset_unix":1700000000,"status":"active"}"#
        StubURLProtocol.responses = [(200, body), (200, body)]
        let service = ElevenLabsAccountService(session: StubURLProtocol.session())
        let health = await service.testConnection(apiKey: sentinel)
        XCTAssertEqual(health, .ok(planName: "starter"))
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/user/subscription")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), sentinel)
        let usage = try await service.fetchUsage(apiKey: sentinel)
        XCTAssertEqual(usage, ProviderUsage(planName: "starter", creditsUsed: 1000, creditsLimit: 10000,
                                            resetsAt: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    func testTestConnectionFailures() async {
        let service = ElevenLabsAccountService(session: StubURLProtocol.session())
        StubURLProtocol.responses = [(401, "{}")]
        let invalid = await service.testConnection(apiKey: sentinel)
        XCTAssertEqual(invalid, .failed(.invalidKey))
        StubURLProtocol.failWith = URLError(.timedOut)
        let network = await service.testConnection(apiKey: sentinel)
        XCTAssertEqual(network, .failed(.network))
    }

    /// A key restricted to Speech to Text has no User (read): ElevenLabs answers 401 missing_permissions
    /// on the subscription call. The key is valid, so the test passes without a plan name.
    func testRestrictedKeyWithoutUserReadStillWorks() async {
        StubURLProtocol.reset()
        let service = ElevenLabsAccountService(session: StubURLProtocol.session())
        let body = #"{"detail":{"status":"missing_permissions","message":"The API key you used is missing the permission user_read to execute this operation."}}"#
        StubURLProtocol.responses = [(401, body)]
        let health = await service.testConnection(apiKey: sentinel)
        XCTAssertEqual(health, .ok(planName: ""))
        XCTAssertEqual(ElevenLabsError.from(httpStatus: 401, body: Data(body.utf8)), .missingPermission)
    }
}

final class ElevenLabsCapabilitiesTests: XCTestCase {
    func testScribeV2Batch() throws {
        let provider = try XCTUnwrap(ProviderRegistry.shared.module(id: STTProviderID.elevenLabs))
        XCTAssertTrue(provider.requiresKey)
        let caps = try XCTUnwrap(provider.models.first { $0.id == "scribe_v2" }?.capabilities)
        XCTAssertEqual(caps.batch?.maxSpeakers, 32)
        XCTAssertEqual(caps.batch?.maxDurationSeconds, 36000)
        XCTAssertEqual(caps.batch?.maxFileBytes, 3_000_000_000)
        XCTAssertNil(caps.batch?.translation)
        XCTAssertEqual(caps.batchDeletion, .byID)
        XCTAssertEqual(caps.realtimeDeletion, .unverified)
    }
}
