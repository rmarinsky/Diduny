@testable import Diduny
import XCTest

// MARK: - Test doubles

private final class MockTokenStore: AuthTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func save(key: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    func read(key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func delete(key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}

/// Routes every request through a stubbed handler so the service never hits the network.
private final class TTSStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession moves the body into a stream; materialize it for assertions.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Tests

@MainActor
final class TTSServiceTests: XCTestCase {
    private var tokenStore: MockTokenStore!

    override func setUp() {
        super.setUp()
        tokenStore = MockTokenStore()
        TTSStubURLProtocol.handler = nil
    }

    override func tearDown() {
        TTSStubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeService(baseURL: String = "https://tts.example.test") -> SixtyDBTTSService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TTSStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return SixtyDBTTSService(session: session, tokenStore: tokenStore, baseURL: baseURL)
    }

    private nonisolated static func httpResponse(_ request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func storeKey() {
        try? tokenStore.save(key: "tts_60db_api_key", value: "test-key")
    }

    // MARK: API key

    func test_toggleSpeak_withoutAPIKeyThrows() async {
        let service = makeService()
        XCTAssertFalse(service.hasAPIKey)

        do {
            try await service.toggleSpeak(versionId: UUID(), text: "Hello", languageCode: nil)
            XCTFail("Expected TTSError.noAPIKey")
        } catch let error as TTSError {
            XCTAssertEqual(error, .noAPIKey)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_saveAPIKey_emptyValueRemovesKey() throws {
        let service = makeService()
        try service.saveAPIKey("abc")
        XCTAssertTrue(service.hasAPIKey)
        try service.saveAPIKey("")
        XCTAssertFalse(service.hasAPIKey)
        try service.saveAPIKey("abc")
        try service.saveAPIKey(nil)
        XCTAssertFalse(service.hasAPIKey)
    }

    // MARK: Synthesis

    func test_toggleSpeak_buildsExpectedRequestAndPlays() async throws {
        storeKey()
        let service = makeService()
        let versionId = UUID()
        var capturedRequest: URLRequest?

        TTSStubURLProtocol.handler = { request in
            capturedRequest = request
            // ~30s of 16-bit mono @ 24kHz so the delegate's finish handler
            // can't race the assertions below.
            let pcm = Data(repeating: 0x7F, count: 24_000 * 2 * 30)
            let json: [String: Any] = [
                "success": true,
                "audio_base64": pcm.base64EncodedString(),
                "sample_rate": 24_000
            ]
            return (Self.httpResponse(request, status: 200),
                    try JSONSerialization.data(withJSONObject: json))
        }

        try await service.toggleSpeak(versionId: versionId, text: "Hello world", languageCode: "en")

        // State
        XCTAssertEqual(service.speakingVersionId, versionId)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertFalse(service.isLoading)

        // Request
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://tts.example.test/tts-synthesize")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        let body = try JSONSerialization.jsonObject(with: TTSStubURLProtocol.body(of: request)) as? [String: Any]
        XCTAssertEqual(body?["text"] as? String, "Hello world")
        XCTAssertEqual(body?["voice_id"] as? String, SixtyDBTTSService.defaultVoiceID.uuidString)
        XCTAssertEqual(body?["timestamp_type"] as? String, "NONE")
        let audioConfig = body?["audio_config"] as? [String: Any]
        XCTAssertEqual(audioConfig?["audio_encoding"] as? String, "LINEAR16")
        XCTAssertEqual(audioConfig?["sample_rate_hertz"] as? Int, 24_000)
        let speed = try XCTUnwrap(body?["speed"] as? Double)
        XCTAssertEqual(speed, SettingsStorage.shared.ttsSpeed, accuracy: 0.0001)

        service.stopSpeaking()
        XCTAssertNil(service.speakingVersionId)
        XCTAssertFalse(service.isSpeaking)
    }

    func test_toggleSpeak_sameVersionTogglesOffWithoutNewRequest() async throws {
        storeKey()
        let service = makeService()
        let versionId = UUID()
        var requestCount = 0

        TTSStubURLProtocol.handler = { request in
            requestCount += 1
            let json: [String: Any] = ["success": true, "audio_base64": Data([0x00, 0x01]).base64EncodedString(), "sample_rate": 16_000]
            return (Self.httpResponse(request, status: 200), try JSONSerialization.data(withJSONObject: json))
        }

        try await service.toggleSpeak(versionId: versionId, text: "First", languageCode: nil)
        XCTAssertEqual(requestCount, 1)

        try await service.toggleSpeak(versionId: versionId, text: "First", languageCode: nil)
        XCTAssertEqual(requestCount, 1, "second tap must stop, not re-synthesize")
        XCTAssertNil(service.speakingVersionId)
    }

    func test_toggleSpeak_apiErrorSurfacesMessage() async {
        storeKey()
        let service = makeService()

        TTSStubURLProtocol.handler = { request in
            let json: [String: Any] = ["success": false, "message": "voice not found"]
            return (Self.httpResponse(request, status: 400), try JSONSerialization.data(withJSONObject: json))
        }

        do {
            try await service.toggleSpeak(versionId: UUID(), text: "Hello", languageCode: nil)
            XCTFail("Expected TTSError.apiError")
        } catch let error as TTSError {
            XCTAssertEqual(error, .apiError(status: 400, message: "voice not found"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertNil(service.speakingVersionId, "state resets on failure")
        XCTAssertFalse(service.isLoading)
    }

    func test_toggleSpeak_successFalseWith200ThrowsNoAudioData() async {
        storeKey()
        let service = makeService()

        TTSStubURLProtocol.handler = { request in
            let json: [String: Any] = ["success": false, "audio_base64": "", "sample_rate": 24_000]
            return (Self.httpResponse(request, status: 200), try JSONSerialization.data(withJSONObject: json))
        }

        do {
            try await service.toggleSpeak(versionId: UUID(), text: "Hello", languageCode: nil)
            XCTFail("Expected TTSError.noAudioData")
        } catch let error as TTSError {
            XCTAssertEqual(error, .noAudioData)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_toggleSpeak_whileLoadingStopCancelsActiveRequest() async throws {
        storeKey()
        let service = makeService()
        let versionId = UUID()

        // Handler that never completes until the test stops the service.
        let started = expectation(description: "request started")
        TTSStubURLProtocol.handler = { request in
            started.fulfill()
            let json: [String: Any] = ["success": true, "audio_base64": Data([0x00]).base64EncodedString(), "sample_rate": 16_000]
            return (Self.httpResponse(request, status: 200), try JSONSerialization.data(withJSONObject: json))
        }

        let speakTask = Task {
            try await service.toggleSpeak(versionId: versionId, text: "Hello", languageCode: nil)
        }
        await fulfillment(of: [started])
        XCTAssertTrue(service.isLoading)
        service.stopSpeaking()
        _ = try? await speakTask.value

        XCTAssertNil(service.speakingVersionId)
        XCTAssertFalse(service.isLoading)
    }

    // MARK: Voices

    func test_fetchVoices_decodesCatalog() async throws {
        storeKey()
        let service = makeService()

        TTSStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/voices")
            XCTAssertEqual(request.url?.query, "model=quality")
            XCTAssertEqual(request.httpMethod, "GET")
            let json = """
            {
              "success": true,
              "data": [
                {
                  "voice_id": "fbb75ed2-975a-40c7-9e06-38e30524a9a1",
                  "name": "Zara",
                  "labels": { "language": "hi", "language_name": "Hindi", "gender": "female" }
                }
              ]
            }
            """
            return (Self.httpResponse(request, status: 200), Data(json.utf8))
        }

        let voices = try await service.fetchVoices()
        XCTAssertEqual(voices.count, 1)
        XCTAssertEqual(voices[0].name, "Zara")
        XCTAssertEqual(service.voices.count, 1)
        XCTAssertFalse(service.isLoadingVoices)
    }

    func test_testConnection_returnsTrueOn200() async throws {
        storeKey()
        let service = makeService()

        TTSStubURLProtocol.handler = { request in
            (Self.httpResponse(request, status: 200), Data("{\"success\": true, \"data\": []}".utf8))
        }

        XCTAssertTrue(try await service.testConnection())
    }

    func test_testConnection_throwsOn401() async {
        storeKey()
        let service = makeService()

        TTSStubURLProtocol.handler = { request in
            (Self.httpResponse(request, status: 401), Data("{\"message\": \"unauthorized\"}".utf8))
        }

        do {
            _ = try await service.testConnection()
            XCTFail("Expected TTSError.apiError")
        } catch let error as TTSError {
            XCTAssertEqual(error, .apiError(status: 401, message: "unauthorized"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
