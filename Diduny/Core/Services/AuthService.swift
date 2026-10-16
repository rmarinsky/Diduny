import Foundation
import os

protocol AuthTokenStore: Sendable {
    func save(key: String, value: String) throws
    func read(key: String) -> String?
    func delete(key: String)
}

@Observable
@MainActor
final class AuthService {
    static let shared = AuthService()

    nonisolated static var hasStoredSession: Bool {
        UserDefaults.standard.bool(forKey: Keys.sessionPresent)
    }

    enum AuthState: Equatable {
        case loggedOut
        case otpSent
        case loggedIn
    }

    private(set) var authState: AuthState
    private(set) var showsMigrationNotice = false
    private(set) var pendingOtpEmail: String?

    var isLoggedIn: Bool { authState == .loggedIn }
    var userEmail: String? { tokenStore.read(key: Keys.userEmail) }

    private enum Keys {
        static let accessToken = "auth_access_token"
        static let refreshToken = "auth_refresh_token"
        static let accessTokenExpiresAt = "auth_access_token_expires_at"
        static let userEmail = "auth_user_email"
        static let sessionPresent = "_diduny_auth_session_present"
        static let migrationNotice = "_diduny_auth_requires_relogin"
    }

    nonisolated private let session: URLSession
    nonisolated private let tokenStore: any AuthTokenStore
    nonisolated private let now: @Sendable () -> Date
    private let baseURLOverride: String?
    private var refreshTask: Task<Void, Error>?
    private var otpFlowGeneration = 0

    private var proxyBaseURL: String {
        (baseURLOverride ?? SettingsStorage.shared.proxyBaseURL)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    init(
        baseURL: String? = nil,
        session: URLSession = .shared,
        tokenStore: any AuthTokenStore = KeychainManager.shared,
        now: @escaping @Sendable () -> Date = { Date() },
        migrateLegacySession: Bool = true
    ) {
        baseURLOverride = baseURL
        self.session = session
        self.tokenStore = tokenStore
        self.now = now
        let hasCompleteSession = tokenStore.read(key: Keys.accessToken) != nil
            && tokenStore.read(key: Keys.refreshToken) != nil
            && tokenStore.read(key: Keys.accessTokenExpiresAt).flatMap(Int64.init) != nil
        authState = hasCompleteSession ? .loggedIn : .loggedOut
        if !hasCompleteSession {
            tokenStore.delete(key: Keys.accessToken)
            tokenStore.delete(key: Keys.refreshToken)
            tokenStore.delete(key: Keys.accessTokenExpiresAt)
            tokenStore.delete(key: Keys.userEmail)
        }
        UserDefaults.standard.set(authState == .loggedIn, forKey: Keys.sessionPresent)

        if migrateLegacySession,
           UserDefaults.standard.bool(forKey: "_diduny_supabase_session_present") {
            UserDefaults.standard.removeObject(forKey: "_diduny_supabase_session_present")
            KeychainManager.shared.delete(
                serviceName: "supabase.gotrue.swift",
                key: "sb-oplmqfsttetsosglilkb-auth-token"
            )
            UserDefaults.standard.set(true, forKey: Keys.migrationNotice)
        }
        showsMigrationNotice = migrateLegacySession
            && UserDefaults.standard.bool(forKey: Keys.migrationNotice)
    }

    func sendOtp(email: String) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidEmail(email) else { throw AuthError.invalidEmail }
        let generation = otpFlowGeneration
        let request = try jsonRequest(path: "/api/v1/auth/send-otp", body: ["email": email])
        _ = try await perform(request, errorPrefix: "Failed to send OTP")
        guard generation == otpFlowGeneration else { return }
        pendingOtpEmail = email
        authState = .otpSent
    }

    nonisolated static func isValidEmail(_ email: String) -> Bool {
        guard !email.contains(where: \Character.isWhitespace) else { return false }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
    }

    func resendOtp() async throws {
        guard let pendingOtpEmail else { throw AuthError.notAuthenticated }
        try await sendOtp(email: pendingOtpEmail)
    }

    func verifyOtp(email: String, code: String) async throws {
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw AuthError.invalidOtp }
        let generation = otpFlowGeneration
        let request = try jsonRequest(
            path: "/api/v1/auth/verify-otp",
            body: ["email": email, "otp": code]
        )
        let data = try await perform(request, errorPrefix: "Verification failed")
        guard generation == otpFlowGeneration else { return }
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        try store(response, email: response.user?.email ?? email)
        UserDefaults.standard.removeObject(forKey: Keys.migrationNotice)
        showsMigrationNotice = false
        pendingOtpEmail = nil
        authState = .loggedIn
    }

    func cancelOtpFlow() {
        otpFlowGeneration &+= 1
        pendingOtpEmail = nil
        authState = .loggedOut
    }

    func logout() async {
        let refreshInFlight = refreshTask
        refreshInFlight?.cancel()
        if let refreshInFlight {
            _ = try? await refreshInFlight.value
        }
        let accessToken = tokenStore.read(key: Keys.accessToken)
        clearTokens()

        if let url = URL(string: "\(proxyBaseURL)/api/v1/auth/logout") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            if let accessToken {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }
            _ = try? await session.data(for: request)
        }
    }

    nonisolated func getAccessToken() async -> String? {
        #if TEST_BUILD
            if let token = ProcessInfo.processInfo.environment["DIDUNY_E2E_ACCESS_TOKEN"],
               !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return token
            }
        #endif

        guard let accessToken = tokenStore.read(key: Keys.accessToken) else { return nil }
        let expiresAt = tokenStore.read(key: Keys.accessTokenExpiresAt).flatMap(Int64.init)
        let nowMilliseconds = Int64(now().timeIntervalSince1970 * 1_000)

        guard let expiresAt, expiresAt - nowMilliseconds > 60_000 else {
            do {
                try await refreshTokens()
                return tokenStore.read(key: Keys.accessToken)
            } catch {
                Log.app.error("[Auth] Token refresh failed: \(error.localizedDescription)")
                return nil
            }
        }

        return accessToken
    }

    nonisolated func authenticatedRequest(_ request: inout URLRequest) async {
        guard let token = await getAccessToken() else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    nonisolated func performWithAuth(
        _ request: URLRequest,
        session: URLSession = .shared
    ) async throws -> (Data, HTTPURLResponse) {
        var authedRequest = request
        await authenticatedRequest(&authedRequest)
        let first = try await Self.data(for: authedRequest, session: session)
        guard first.1.statusCode == 401 else { return first }

        try await refreshTokens()
        var retryRequest = request
        await authenticatedRequest(&retryRequest)
        return try await Self.data(for: retryRequest, session: session)
    }

    nonisolated func performUploadWithAuth(
        _ request: URLRequest,
        bodyFileURL: URL,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        func upload(_ sourceRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
            var authedRequest = sourceRequest
            await authenticatedRequest(&authedRequest)
            let requestId = HTTPLogger.attachRequestId(&authedRequest)
            HTTPLogger.logRequest(authedRequest, requestId: requestId)
            let startTime = ContinuousClock.now
            let (data, response) = try await session.upload(for: authedRequest, fromFile: bodyFileURL)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthError.invalidResponse
            }
            HTTPLogger.logResponse(data: data, response: httpResponse, requestId: requestId, startTime: startTime)
            return (data, httpResponse)
        }

        let first = try await upload(request)
        guard first.1.statusCode == 401 else { return first }
        try await refreshTokens()
        return try await upload(request)
    }

    func refreshTokens() async throws {
        if let refreshTask {
            return try await refreshTask.value
        }

        let task = Task { @MainActor in try await performTokenRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func performTokenRefresh() async throws {
        guard let refreshToken = tokenStore.read(key: Keys.refreshToken) else {
            throw AuthError.notAuthenticated
        }

        let request = try jsonRequest(
            path: "/api/v1/auth/refresh",
            body: ["refreshToken": refreshToken]
        )

        do {
            let data = try await perform(request, errorPrefix: "Token refresh failed")
            let response: TokenResponse
            do {
                response = try JSONDecoder().decode(TokenResponse.self, from: data)
            } catch {
                clearTokens()
                throw error
            }
            try store(response, email: userEmail)
            authState = .loggedIn
        } catch AuthError.notAuthenticated {
            clearTokens()
            throw AuthError.notAuthenticated
        }
    }

    private func jsonRequest(path: String, body: [String: String]) throws -> URLRequest {
        guard let url = URL(string: "\(proxyBaseURL)\(path)") else { throw AuthError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func perform(_ request: URLRequest, errorPrefix: String) async throws -> Data {
        let (data, response) = try await Self.data(for: request, session: session)
        if response.statusCode == 401 { throw AuthError.notAuthenticated }
        guard (200 ... 299).contains(response.statusCode) else {
            throw AuthError.serverError("\(errorPrefix) (\(response.statusCode))")
        }
        return data
    }

    nonisolated private static func data(
        for sourceRequest: URLRequest,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        var request = sourceRequest
        let requestId = HTTPLogger.attachRequestId(&request)
        HTTPLogger.logRequest(request, requestId: requestId)
        let startTime = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        HTTPLogger.logResponse(data: data, response: httpResponse, requestId: requestId, startTime: startTime)
        return (data, httpResponse)
    }

    private func store(_ response: TokenResponse, email: String?) throws {
        do {
            try tokenStore.save(key: Keys.refreshToken, value: response.refreshToken)
            try tokenStore.save(key: Keys.accessToken, value: response.accessToken)
            try tokenStore.save(key: Keys.accessTokenExpiresAt, value: String(response.accessTokenExpiresAt))
            if let email, !email.isEmpty {
                try tokenStore.save(key: Keys.userEmail, value: email)
            }
            UserDefaults.standard.set(true, forKey: Keys.sessionPresent)
        } catch {
            clearTokens()
            throw error
        }
    }

    private func clearTokens() {
        AnalyticsService.shared.reset()
        otpFlowGeneration &+= 1
        tokenStore.delete(key: Keys.accessToken)
        tokenStore.delete(key: Keys.refreshToken)
        tokenStore.delete(key: Keys.accessTokenExpiresAt)
        tokenStore.delete(key: Keys.userEmail)
        UserDefaults.standard.set(false, forKey: Keys.sessionPresent)
        pendingOtpEmail = nil
        authState = .loggedOut
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let accessTokenExpiresAt: Int64
    let refreshToken: String
    let user: AuthUser?
}

private struct AuthUser: Decodable {
    let email: String
}

enum AuthError: LocalizedError {
    case invalidEmail
    case invalidOtp
    case invalidURL
    case invalidResponse
    case notAuthenticated
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail: "Enter a valid email address"
        case .invalidOtp: "Enter the six-digit code"
        case .invalidURL: "Invalid auth URL"
        case .invalidResponse: "Invalid server response"
        case .notAuthenticated: "Not authenticated — please log in"
        case let .serverError(message): message
        }
    }
}
