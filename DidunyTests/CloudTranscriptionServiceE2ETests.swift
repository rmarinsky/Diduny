import Foundation
import Supabase
import XCTest
@testable import Diduny

final class CloudTranscriptionServiceE2ETests: XCTestCase {
    private struct MailpitMessage: Decodable {
        struct Recipient: Decodable {
            let Address: String
        }

        let To: [Recipient]
        let Snippet: String
    }

    private struct MailpitMessagesResponse: Decodable {
        let messages: [MailpitMessage]
    }

    private struct Sentence: Decodable {
        let orig: String
        let trans: String
    }

    private struct TranslationResponse: Decodable {
        let src: String
        let sentences: [Sentence]
    }

    private enum E2EError: Error {
        case timeout
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private func isOptInEnabled() -> Bool {
        ProcessInfo.processInfo.environment["DIDUNY_E2E_NATIVE"] == "1"
    }

    private func waitForOTPCode(
        email: String,
        mailpitURL: String,
        maxAttempts: Int = 30,
        delayMilliseconds: UInt64 = 500,
    ) async throws -> String {
        for _ in 0..<maxAttempts {
            let request = URLRequest(url: URL(string: "\(mailpitURL)/api/v1/messages")!)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                continue
            }

            let responseBody = try JSONDecoder().decode(
                MailpitMessagesResponse.self,
                from: data,
            )
            if let match = responseBody.messages.first(where: { message in
                message.To.contains { $0.Address == email }
            }),
            let range = match.Snippet.range(
                of: #"\b\d{6}\b"#,
                options: .regularExpression
            ) {
                return String(match.Snippet[range])
            }

            try await Task.sleep(for: .milliseconds(delayMilliseconds))
        }
        throw E2EError.timeout
    }

    @MainActor
    private func ensureOtpSession(
        mailpitURL: String,
    ) async throws -> Session {
        if let session = await SupabaseService.shared.currentSession {
            return session
        }

        let env = ProcessInfo.processInfo.environment
        let email = nonEmpty(env["DIDUNY_E2E_OTP_EMAIL"])
            ?? "diduny-e2e-\(UUID().uuidString.lowercased())@example.com"

        try await AuthService.shared.sendOtp(email: email)
        let code = try await waitForOTPCode(email: email, mailpitURL: mailpitURL)
        try await AuthService.shared.verifyOtp(email: email, code: code)

        guard let session = await SupabaseService.shared.currentSession else {
            throw XCTSkip("OTP flow completed but session is not available in this build.")
        }
        return session
    }

    private func translationRequest(
        proxyBaseURL: String,
        token: String,
        sourceLanguage: String,
        targetLanguage: String,
        text: String,
    ) async throws -> (statusCode: Int, data: Data) {
        let requestURL = URL(string: "\(proxyBaseURL)/api/v1/translations")!
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "sl": sourceLanguage,
                "tl": targetLanguage,
                "q": text,
            ],
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        return (httpResponse.statusCode, data)
    }

    private func makeRealtimeURL(
        proxyBaseURL: String,
        token: String,
    ) throws -> URL {
        guard let base = URL(string: proxyBaseURL) else {
            throw AuthError.invalidURL
        }
        var components = URLComponents()
        components.scheme = base.scheme
        components.host = base.host
        components.port = base.port
        let basePath = base.path.isEmpty ? "" : base.path
        let apiPath = "\(basePath)/api/v1/realtime"
        components.path = apiPath.replacingOccurrences(of: "//api/v1/realtime", with: "/api/v1/realtime")
        components.queryItems = [URLQueryItem(name: "token", value: token)]

        guard let url = components.url else {
            throw AuthError.invalidURL
        }
        return url
    }

    private func receiveSocketMessage(
        _ task: URLSessionWebSocketTask,
        timeoutSeconds: UInt64 = 8,
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(
            of: URLSessionWebSocketTask.Message.self,
            returning: URLSessionWebSocketTask.Message.self,
        ) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw E2EError.timeout
            }

            guard let first = try await group.next() else {
                throw E2EError.timeout
            }
            group.cancelAll()
            return first
        }
    }

    private func realtimeConfigPayload() throws -> String {
        let payload = [
            "audio_format": "s16le",
            "sample_rate": 16000,
            "num_channels": 1,
        ] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    func test_supabaseOtpLoginFlowViaEmail() async throws {
        guard isOptInEnabled() else {
            throw XCTSkip("Set DIDUNY_E2E_NATIVE=1 to run local native/backend e2e.")
        }
        guard nonEmpty(ProcessInfo.processInfo.environment["DIDUNY_E2E_PROXY_BASE_URL"]) != nil else {
            throw XCTSkip("DIDUNY_E2E_PROXY_BASE_URL is required.")
        }
        let mailpitURL =
            nonEmpty(ProcessInfo.processInfo.environment["DIDUNY_E2E_MAILPIT_URL"])
            ?? nonEmpty(ProcessInfo.processInfo.environment["DIDUNY_MAILPIT_URL"])
            ?? "http://127.0.0.1:55324"
        guard !mailpitURL.isEmpty else {
            throw XCTSkip("DIDUNY_E2E_MAILPIT_URL is required for OTP verification.")
        }

        let session = try await ensureOtpSession(mailpitURL: mailpitURL)
        XCTAssertNotNil(session.user.email)
        XCTAssertFalse(nonEmpty(session.accessToken)?.isEmpty ?? true)
    }

    @MainActor
    func test_authRefreshTokens_withActiveSession() async throws {
        guard isOptInEnabled() else {
            throw XCTSkip("Set DIDUNY_E2E_NATIVE=1 to run local native/backend e2e.")
        }
        guard nonEmpty(ProcessInfo.processInfo.environment["DIDUNY_E2E_PROXY_BASE_URL"]) != nil else {
            throw XCTSkip("DIDUNY_E2E_PROXY_BASE_URL is required.")
        }
        let mailpitURL =
            nonEmpty(ProcessInfo.processInfo.environment["DIDUNY_E2E_MAILPIT_URL"])
            ?? nonEmpty(ProcessInfo.processInfo.environment["DIDUNY_MAILPIT_URL"])
            ?? "http://127.0.0.1:55324"
        guard !mailpitURL.isEmpty else {
            throw XCTSkip("DIDUNY_E2E_MAILPIT_URL is required for OTP verification.")
        }

        _ = try await ensureOtpSession(mailpitURL: mailpitURL)
        try await AuthService.shared.refreshTokens()

        let session = await SupabaseService.shared.currentSession
        XCTAssertNotNil(session?.accessToken)
    }

    @MainActor
    func test_httpJwtIsValidatedForTranslationEndpoint() async throws {
        guard isOptInEnabled() else {
            throw XCTSkip("Set DIDUNY_E2E_NATIVE=1 to run local native/backend e2e.")
        }
        guard let proxyBaseURL = nonEmpty(ProcessInfo.processInfo.environment["DIDUNY_E2E_PROXY_BASE_URL"]) else {
            throw XCTSkip("DIDUNY_E2E_PROXY_BASE_URL is required.")
        }
        guard let sourceLanguage = nonEmpty(ProcessInfo.processInfo.environment["DIDUNY_E2E_SOURCE_LANGUAGE"]) else {
            throw XCTSkip("DIDUNY_E2E_SOURCE_LANGUAGE is required.")
        }
        guard let targetLanguage = nonEmpty(ProcessInfo.processInfo.environment["DIDUNY_E2E_TARGET_LANGUAGE"]) else {
            throw XCTSkip("DIDUNY_E2E_TARGET_LANGUAGE is required.")
        }

        let sessionToken = await SupabaseService.shared.currentSession?.accessToken
        let validToken = nonEmpty(ProcessInfo.processInfo.environment["DIDUNY_E2E_ACCESS_TOKEN"])
            ?? nonEmpty(sessionToken)
        guard let validToken else {
            throw XCTSkip("DIDUNY_E2E_ACCESS_TOKEN or active Supabase session is required.")
        }

        let fixtureText = ProcessInfo.processInfo.environment["DIDUNY_E2E_EXPECTED_TEXT"]
            ?? "Translation test: will it translate?"

        let invalidResponse = try await translationRequest(
            proxyBaseURL: proxyBaseURL,
            token: "invalid-local-token",
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            text: fixtureText,
        )
        XCTAssertEqual(invalidResponse.statusCode, 401)

        let validResponse = try await translationRequest(
            proxyBaseURL: proxyBaseURL,
            token: validToken,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            text: fixtureText,
        )
        XCTAssertEqual(validResponse.statusCode, 200)
        let parsed = try JSONDecoder().decode(TranslationResponse.self, from: validResponse.data)
        XCTAssertEqual(parsed.src, sourceLanguage)
        XCTAssertTrue(parsed.sentences.contains(where: { !$0.trans.isEmpty }))
    }

    @MainActor
    func test_webSocketJwtAllowsValidSessionAndRejectsInvalid() async throws {
        guard isOptInEnabled() else {
            throw XCTSkip("Set DIDUNY_E2E_NATIVE=1 to run local native/backend e2e.")
        }
        guard let proxyBaseURL = nonEmpty(ProcessInfo.processInfo.environment["DIDUNY_E2E_PROXY_BASE_URL"]) else {
            throw XCTSkip("DIDUNY_E2E_PROXY_BASE_URL is required.")
        }
        let mailpitURL =
            nonEmpty(ProcessInfo.processInfo.environment["DIDUNY_E2E_MAILPIT_URL"])
            ?? nonEmpty(ProcessInfo.processInfo.environment["DIDUNY_MAILPIT_URL"])
            ?? "http://127.0.0.1:55324"
        guard !mailpitURL.isEmpty else {
            throw XCTSkip("DIDUNY_E2E_MAILPIT_URL is required for session bootstrap.")
        }

        let session = try await ensureOtpSession(mailpitURL: mailpitURL)
        let validToken = session.accessToken
        let invalidToken = "invalid-local-token"

        let validURL = try makeRealtimeURL(proxyBaseURL: proxyBaseURL, token: validToken)
        let invalidURL = try makeRealtimeURL(proxyBaseURL: proxyBaseURL, token: invalidToken)
        let config = try realtimeConfigPayload()

        let sessionConfig = URLSession(configuration: .default)

        let validTask = sessionConfig.webSocketTask(with: validURL)
        validTask.resume()
        defer { validTask.cancel() }
        try await validTask.send(URLSessionWebSocketTask.Message.string(config))
        let validMessage = try await receiveSocketMessage(validTask)
        if case let .string(text) = validMessage {
            XCTAssertTrue(text.contains("proxy_ready"))
        } else {
            XCTFail("Expected proxy_ready text frame for valid websocket token.")
        }

        let invalidTask = sessionConfig.webSocketTask(with: invalidURL)
        invalidTask.resume()
        defer { invalidTask.cancel() }
        try await invalidTask.send(URLSessionWebSocketTask.Message.string(config))
        do {
            _ = try await receiveSocketMessage(invalidTask)
            XCTFail("Expected websocket handshake/message failure for invalid token.")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func test_translateDidunyFixtureViaConfiguredProxy() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DIDUNY_E2E_NATIVE"] == "1" else {
            throw XCTSkip("Set DIDUNY_E2E_NATIVE=1 to run local native/backend e2e.")
        }

        guard let proxyBaseURL = nonEmpty(env["DIDUNY_E2E_PROXY_BASE_URL"]) else {
            throw XCTSkip("DIDUNY_E2E_PROXY_BASE_URL is required.")
        }
        guard let audioPath = nonEmpty(env["DIDUNY_E2E_AUDIO_PATH"]) else {
            throw XCTSkip("DIDUNY_E2E_AUDIO_PATH is required.")
        }
        guard nonEmpty(env["DIDUNY_E2E_ACCESS_TOKEN"]) != nil else {
            throw XCTSkip("DIDUNY_E2E_ACCESS_TOKEN is required.")
        }

        let expectedText = env["DIDUNY_E2E_EXPECTED_TEXT"] ?? "Translation test: will it translate?"
        let sourceLanguage = env["DIDUNY_E2E_SOURCE_LANGUAGE"] ?? "uk"
        let targetLanguage = env["DIDUNY_E2E_TARGET_LANGUAGE"] ?? "en"

        SettingsStorage.shared.proxyBaseURL = proxyBaseURL
        SettingsStorage.shared.favoriteLanguages = [sourceLanguage]
        SettingsStorage.shared.translationTargetLanguages = [targetLanguage]
        SettingsStorage.shared.voiceTranslationTargetLanguage = targetLanguage

        let audioData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        let text = try await CloudTranscriptionService()
            .translateAndTranscribe(audioData: audioData)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(text, expectedText)
    }
}
