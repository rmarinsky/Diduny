import XCTest
@testable import Diduny

final class AuthServiceTests: XCTestCase {
    private let sessionPresentKey = "_diduny_auth_session_present"
    private let migrationNoticeKey = "_diduny_auth_requires_relogin"
    private let legacySessionPresentKey = "_diduny_supabase_session_present"
    private var storedDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in [sessionPresentKey, migrationNoticeKey, legacySessionPresentKey] {
            storedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        MockAuthURLProtocol.handler = nil
        for key in [sessionPresentKey, migrationNoticeKey, legacySessionPresentKey] {
            if let value = storedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        storedDefaults.removeAll()
        super.tearDown()
    }

    func test_legacySessionRequiresNewSignInBeforeLocalAccess() {
        UserDefaults.standard.set(true, forKey: legacySessionPresentKey)

        XCTAssertFalse(AuthService.hasStoredSession)
    }

    @MainActor
    func test_initClearsPreexistingPartialCredentials() {
        let store = MemoryAuthTokenStore(values: ["auth_access_token": "orphaned-access"])

        let service = makeService(store: store) { request in
            Self.response(for: request, body: #"{"message":"unused"}"#)
        }

        XCTAssertEqual(service.authState, .loggedOut)
        XCTAssertNil(store.read(key: "auth_access_token"))
        XCTAssertFalse(AuthService.hasStoredSession)
    }

    @MainActor
    func test_sendOtp_postsToOwnedBackendAndTransitionsToOtpSent() async throws {
        let service = makeService { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/send-otp")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String],
                ["email": "roman@example.com"]
            )
            return Self.response(for: request, body: #"{"message":"OTP sent"}"#)
        }

        try await service.sendOtp(email: "roman@example.com")

        XCTAssertEqual(service.authState, .otpSent)
        XCTAssertEqual(service.pendingOtpEmail, "roman@example.com")
    }

    @MainActor
    func test_sendOtpRejectsMalformedEmailBeforeNetworkRequest() async {
        let service = makeService { request in
            XCTFail("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
            return Self.response(for: request, body: #"{"message":"unused"}"#)
        }

        for email in ["", "roman", "@example.com", "roman@", "roman@example"] {
            do {
                try await service.sendOtp(email: email)
                XCTFail("Expected invalid email: \(email)")
            } catch {
                guard let authError = error as? AuthError, case .invalidEmail = authError else {
                    return XCTFail("Expected invalidEmail, got \(error)")
                }
            }
        }
    }

    @MainActor
    func test_verifyOtpRejectsMalformedCodeBeforeNetworkRequest() async {
        let service = makeService { request in
            XCTFail("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
            return Self.response(for: request, body: #"{"message":"unused"}"#)
        }

        for code in ["", "12345", "1234567", "12A456", "١٢٣٤٥٦"] {
            do {
                try await service.verifyOtp(email: "roman@example.com", code: code)
                XCTFail("Expected invalid OTP: \(code)")
            } catch {
                guard let authError = error as? AuthError, case .invalidOtp = authError else {
                    return XCTFail("Expected invalidOtp, got \(error)")
                }
            }
        }
    }

    @MainActor
    func test_resendUsesSharedOtpDestinationAndCancellationClearsIt() async throws {
        let service = makeService { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/send-otp")
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String],
                ["email": "roman@example.com"]
            )
            return Self.response(for: request, body: #"{"message":"OTP sent"}"#)
        }

        try await service.sendOtp(email: "roman@example.com")
        try await service.resendOtp()

        XCTAssertEqual(service.pendingOtpEmail, "roman@example.com")

        service.cancelOtpFlow()

        XCTAssertEqual(service.authState, .loggedOut)
        XCTAssertNil(service.pendingOtpEmail)
    }

    @MainActor
    func test_cancelIgnoresLateResendResponse() async throws {
        let service = makeService { request in
            Self.response(for: request, body: #"{"message":"OTP sent"}"#)
        }
        try await service.sendOtp(email: "roman@example.com")

        let requestStarted = expectation(description: "Resend request started")
        let allowResponse = DispatchSemaphore(value: 0)
        MockAuthURLProtocol.handler = { request in
            requestStarted.fulfill()
            _ = allowResponse.wait(timeout: .now() + 2)
            return Self.response(for: request, body: #"{"message":"OTP sent"}"#)
        }

        let resend = Task { try await service.resendOtp() }
        await fulfillment(of: [requestStarted], timeout: 2)
        service.cancelOtpFlow()
        allowResponse.signal()
        try await resend.value

        XCTAssertEqual(service.authState, .loggedOut)
        XCTAssertNil(service.pendingOtpEmail)
    }

    @MainActor
    func test_cancelIgnoresLateVerificationResponse() async throws {
        let store = MemoryAuthTokenStore()
        let service = makeService(store: store) { request in
            Self.response(for: request, body: #"{"message":"OTP sent"}"#)
        }
        try await service.sendOtp(email: "roman@example.com")

        let requestStarted = expectation(description: "Verification request started")
        let allowResponse = DispatchSemaphore(value: 0)
        MockAuthURLProtocol.handler = { request in
            requestStarted.fulfill()
            _ = allowResponse.wait(timeout: .now() + 2)
            return Self.response(
                for: request,
                body: #"{"accessToken":"access","accessTokenExpiresAt":2000000,"refreshToken":"refresh"}"#
            )
        }

        let verification = Task {
            try await service.verifyOtp(email: "roman@example.com", code: "123456")
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        service.cancelOtpFlow()
        allowResponse.signal()
        try await verification.value

        XCTAssertEqual(service.authState, .loggedOut)
        XCTAssertNil(store.read(key: "auth_access_token"))
        XCTAssertNil(store.read(key: "auth_refresh_token"))
    }

    @MainActor
    func test_verifyOtpStoresOwnedTokensAndUser() async throws {
        let store = MemoryAuthTokenStore()
        let service = makeService(store: store) { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/verify-otp")
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String],
                ["email": "roman@example.com", "otp": "123456"]
            )
            return Self.response(
                for: request,
                body: #"{"accessToken":"access","accessTokenExpiresAt":2000000,"refreshToken":"refresh","user":{"id":"user-1","email":"roman@example.com"}}"#
            )
        }

        try await service.verifyOtp(email: "roman@example.com", code: "123456")

        XCTAssertEqual(store.read(key: "auth_access_token"), "access")
        XCTAssertEqual(store.read(key: "auth_refresh_token"), "refresh")
        XCTAssertEqual(store.read(key: "auth_access_token_expires_at"), "2000000")
        XCTAssertEqual(store.read(key: "auth_user_email"), "roman@example.com")
        XCTAssertEqual(service.authState, .loggedIn)
    }

    @MainActor
    func test_getAccessTokenRefreshesWhenExpiryIsNear() async throws {
        let store = MemoryAuthTokenStore(values: [
            "auth_access_token": "old-access",
            "auth_access_token_expires_at": "1050000",
            "auth_refresh_token": "old-refresh",
            "auth_user_email": "roman@example.com",
        ])
        let service = makeService(store: store) { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/refresh")
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String],
                ["refreshToken": "old-refresh"]
            )
            return Self.response(
                for: request,
                body: #"{"accessToken":"new-access","accessTokenExpiresAt":2000000,"refreshToken":"new-refresh"}"#
            )
        }

        let token = await service.getAccessToken()

        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(store.read(key: "auth_refresh_token"), "new-refresh")
    }

    @MainActor
    func test_refreshClearsPartialCredentialsWhenRotatedTokenPersistenceFails() async {
        let store = MemoryAuthTokenStore(
            values: [
                "auth_access_token": "old-access",
                "auth_access_token_expires_at": "1050000",
                "auth_refresh_token": "old-refresh",
                "auth_user_email": "roman@example.com",
            ],
            failOnSaveKey: "auth_access_token"
        )
        let service = makeService(store: store) { request in
            Self.response(
                for: request,
                body: #"{"accessToken":"new-access","accessTokenExpiresAt":2000000,"refreshToken":"new-refresh"}"#
            )
        }

        let token = await service.getAccessToken()

        XCTAssertNil(token)
        XCTAssertNil(store.read(key: "auth_access_token"))
        XCTAssertNil(store.read(key: "auth_refresh_token"))
        XCTAssertNil(store.read(key: "auth_access_token_expires_at"))
        XCTAssertNil(store.read(key: "auth_user_email"))
        XCTAssertEqual(service.authState, .loggedOut)
    }

    @MainActor
    func test_refreshClearsCredentialsWhenRotatedResponseCannotBeDecoded() async {
        let store = MemoryAuthTokenStore(values: [
            "auth_access_token": "old-access",
            "auth_access_token_expires_at": "1050000",
            "auth_refresh_token": "old-refresh",
            "auth_user_email": "roman@example.com",
        ])
        let service = makeService(store: store) { request in
            Self.response(for: request, body: #"{"accessToken":"new-access"}"#)
        }

        let token = await service.getAccessToken()

        XCTAssertNil(token)
        XCTAssertNil(store.read(key: "auth_access_token"))
        XCTAssertNil(store.read(key: "auth_refresh_token"))
        XCTAssertNil(store.read(key: "auth_access_token_expires_at"))
        XCTAssertNil(store.read(key: "auth_user_email"))
        XCTAssertEqual(service.authState, .loggedOut)
    }

    @MainActor
    func test_logoutRevokesBearerSessionAndClearsLocalTokens() async throws {
        let store = MemoryAuthTokenStore(values: [
            "auth_access_token": "access",
            "auth_access_token_expires_at": "2000000",
            "auth_refresh_token": "refresh",
            "auth_user_email": "roman@example.com",
        ])
        let service = makeService(store: store) { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/logout")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            XCTAssertEqual(request.timeoutInterval, 10)
            XCTAssertNil(store.read(key: "auth_access_token"))
            XCTAssertNil(store.read(key: "auth_refresh_token"))
            return Self.response(for: request, body: #"{"message":"Logged out"}"#)
        }

        await service.logout()

        XCTAssertNil(store.read(key: "auth_access_token"))
        XCTAssertNil(store.read(key: "auth_refresh_token"))
        XCTAssertNil(store.read(key: "auth_access_token_expires_at"))
        XCTAssertNil(store.read(key: "auth_user_email"))
        XCTAssertEqual(service.authState, .loggedOut)
    }

    func test_authErrorDescriptions() {
        XCTAssertEqual(AuthError.invalidURL.errorDescription, "Invalid auth URL")
        XCTAssertEqual(AuthError.invalidOtp.errorDescription, "Enter the six-digit code")
        XCTAssertEqual(AuthError.invalidResponse.errorDescription, "Invalid server response")
        XCTAssertEqual(AuthError.notAuthenticated.errorDescription, "Not authenticated — please log in")
        XCTAssertEqual(AuthError.serverError("Rate limited").errorDescription, "Rate limited")
    }

    @MainActor
    private func makeService(
        store: MemoryAuthTokenStore = MemoryAuthTokenStore(),
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> AuthService {
        MockAuthURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAuthURLProtocol.self]
        return AuthService(
            baseURL: "https://api.test",
            session: URLSession(configuration: configuration),
            tokenStore: store,
            now: { Date(timeIntervalSince1970: 1_000) },
            migrateLegacySession: false
        )
    }

    private static func response(
        for request: URLRequest,
        status: Int = 200,
        body: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
        )
    }
}

private final class MemoryAuthTokenStore: AuthTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private let failOnSaveKey: String?

    init(values: [String: String] = [:], failOnSaveKey: String? = nil) {
        self.values = values
        self.failOnSaveKey = failOnSaveKey
    }

    func save(key: String, value: String) throws {
        if key == failOnSaveKey { throw TestStoreError.saveFailed }
        lock.withLock { values[key] = value }
    }

    func read(key: String) -> String? {
        lock.withLock { values[key] }
    }

    func delete(key: String) {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }
}

private enum TestStoreError: Error {
    case saveFailed
}

private final class MockAuthURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            var handledRequest = request
            if handledRequest.httpBody == nil, let stream = handledRequest.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 1_024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(buffer, count: count)
                }
                handledRequest.httpBody = body
            }
            let (response, data) = try Self.handler!(handledRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class OptionalAnalyticsTests: XCTestCase {
    func test_withdrawalDuringRefreshRejectsStaleEnabledResponse() async {
        var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var events = 0
        let service = AnalyticsService(baseURL: { "https://race.example" }, account: { "race@example.test" }) { request in
            if request.url!.path.hasSuffix("events") { events += 1 }
            if request.httpMethod == "GET" {
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            let enabled = String(data: request.httpBody ?? Data(), encoding: .utf8)?.contains("true") == true
            return (Data("{\"enabled\":\(enabled),\"revision\":\"revision\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await service.setEnabled(true)
        let refresh = Task { await service.refresh() }
        while pending == nil { await Task.yield() }
        await service.setEnabled(false)
        XCTAssertFalse(service.enabled)
        pending?.resume(returning: (Data(#"{"enabled":true,"revision":"old"}"#.utf8), HTTPURLResponse(url: URL(string:"https://race.example")!, statusCode:200,httpVersion:nil,headerFields:nil)!))
        await refresh.value
        await service.record(duration: 10, mode: "local", scenario: "dictation")
        XCTAssertFalse(service.enabled)
        XCTAssertEqual(events, 0)
    }

    func test_defaultOffAndWithdrawalStopsEventsWithoutChangingAccount() async {
        var paths: [String] = []
        let service = AnalyticsService(baseURL: { "https://test.example" }, account: { "a@example.test" }) { request in
            paths.append(request.url!.path)
            let enabled = String(data: request.httpBody ?? Data(), encoding: .utf8)?.contains("true") == true
            let body = request.url!.path.hasSuffix("consent") ? "{\"enabled\":\(enabled),\"revision\":\"revision-1\"}" : "{\"accepted\":true}"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await service.record(duration: 12, mode: "local", scenario: "dictation")
        XCTAssertTrue(paths.isEmpty)
        await service.setEnabled(true)
        await service.record(duration: 12, mode: "local", scenario: "dictation")
        XCTAssertEqual(paths.filter { $0.hasSuffix("events") }.count, 1)
        await service.setEnabled(false)
        await service.record(duration: 12, mode: "local", scenario: "dictation")
        XCTAssertEqual(paths.filter { $0.hasSuffix("events") }.count, 1)
        XCTAssertFalse(service.enabled)
    }
}

@MainActor
final class AppLaunchLifecycleTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "AppLaunchLifecycleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func ok(_ request: URLRequest, _ body: String) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func test_launchesReportFirstRunCleanRestartAndUncleanExitAcrossReboot() {
        let defaults = isolatedDefaults()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var boot = "boot-a"
        func tracker() -> AppLaunchTracker { AppLaunchTracker(defaults: defaults, bootID: { boot }, now: { clock }) }

        let firstProcess = tracker()
        let first = firstProcess.begin()
        XCTAssertEqual(first.previousExit, .firstRun)
        XCTAssertNil(first.previousSessionMs)
        XCTAssertFalse(first.rebootedSinceLast)
        XCTAssertEqual(firstProcess.current, first)

        clock += 90
        firstProcess.markCleanExit()
        clock += 5
        let second = tracker().begin()
        XCTAssertEqual(second.previousExit, .clean)
        XCTAssertEqual(second.previousSessionMs, 90000)
        XCTAssertFalse(second.rebootedSinceLast)
        XCTAssertNotEqual(second.sessionID, first.sessionID)

        // Second process crashes (no markCleanExit), then the Mac reboots.
        clock += 600
        boot = "boot-b"
        let third = tracker().begin()
        XCTAssertEqual(third.previousExit, .unclean)
        XCTAssertNil(third.previousSessionMs)
        XCTAssertTrue(third.rebootedSinceLast)
        XCTAssertEqual(third.bootID, "boot-b")
    }

    func test_bootIDIsASaltedHexDigestStablePerInstall() {
        let salt = Data(repeating: 1, count: 32)
        let id = AppLaunchTracker.hashedBootSessionID(salt: salt)
        XCTAssertEqual(id.count, 64)
        XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(id, AppLaunchTracker.hashedBootSessionID(salt: salt))
        XCTAssertNotEqual(id, AppLaunchTracker.hashedBootSessionID(salt: Data(repeating: 2, count: 32)))

        let defaults = isolatedDefaults()
        XCTAssertEqual(AppLaunchTracker(defaults: defaults).begin().bootID,
                       AppLaunchTracker(defaults: defaults).begin().bootID,
                       "The salt persists, so launches in one boot share a boot id")
    }

    func test_hardwareArchitectureReportsTheMacNotTheProcess() {
        XCTAssertEqual(AppLaunchTracker.hardwareArchitecture(arm64Flag: 1), "arm64")
        XCTAssertEqual(AppLaunchTracker.hardwareArchitecture(arm64Flag: 0), "x86_64")
        XCTAssertEqual(AppLaunchTracker.hardwareArchitecture(arm64Flag: nil), "x86_64",
                       "Intel Macs may not define hw.optional.arm64 at all")
        #if arch(arm64)
            XCTAssertEqual(AppLaunchTracker.hardwareArchitecture(), "arm64")
        #endif
    }

    func test_launchCarriesTheAppSessionOnlyWithConsent() async throws {
        let sessionID = UUID()
        var bodies: [String: [String: Any]] = [:]
        let service = AnalyticsService(baseURL: { "https://test.example" }, account: { "a@example.test" }) { request in
            let path = request.url!.lastPathComponent
            if path == "consent" {
                let enabled = String(data: request.httpBody ?? Data(), encoding: .utf8)?.contains("true") == true
                return self.ok(request, "{\"enabled\":\(enabled),\"revision\":\"rev-1\"}")
            }
            bodies[path] = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            return self.ok(request, "{\"accepted\":true}")
        }
        let launch = AppLaunch(sessionID: sessionID, bootID: String(repeating: "a", count: 64),
                               previousExit: .clean, previousSessionMs: 1234, rebootedSinceLast: false)

        await service.recordLaunch(launch, appVersion: "1.15.0", osVersion: "15.1", arch: "arm64")
        XCTAssertTrue(bodies.isEmpty, "Nothing is sent before consent")

        await service.setEnabled(true)
        await service.recordLaunch(launch, appVersion: "1.15.0", osVersion: "15.1", arch: "arm64")
        await service.record(duration: 3, mode: "cloud", scenario: "dictation")

        let sent = try XCTUnwrap(bodies["launches"])
        XCTAssertEqual(Set(sent.keys), ["id", "revision", "appSessionId", "bootId", "previousExit",
                                        "previousSessionMs", "rebootedSinceLast", "appVersion", "osVersion", "arch"])
        XCTAssertEqual(sent["revision"] as? String, "rev-1")
        XCTAssertEqual(sent["appSessionId"] as? String, sessionID.uuidString.lowercased())
        XCTAssertEqual(sent["previousExit"] as? String, "clean")
        XCTAssertEqual(sent["previousSessionMs"] as? Int, 1234)
        XCTAssertEqual(sent["rebootedSinceLast"] as? Bool, false)
        XCTAssertEqual(sent["arch"] as? String, "arm64")
        XCTAssertNil(bodies["events"]?["appSessionId"], "Usage events keep the shipped schema")
    }
}
