import Foundation
import os

@Observable
@MainActor
final class AuthService {
    static let shared = AuthService()

    enum AuthState {
        case loggedOut
        case otpSent
        case loggedIn
    }

    private(set) var authState: AuthState = .loggedOut
    private var authStateResolved = false

    var isLoggedIn: Bool {
        resolveAuthStateIfNeeded()
        return KeychainManager.shared.read(key: Keys.accessToken) != nil
    }

    var userEmail: String? {
        resolveAuthStateIfNeeded()
        return KeychainManager.shared.read(key: Keys.userEmail)
    }

    private enum Keys {
        static let accessToken = "auth_access_token"
        static let refreshToken = "auth_refresh_token"
        static let userEmail = "auth_user_email"
    }

    private var proxyBaseURL: String {
        SettingsStorage.shared.proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private init() {}

    /// Lazily resolve auth state on first access instead of at app launch.
    private func resolveAuthStateIfNeeded() {
        guard !authStateResolved else { return }
        authStateResolved = true
        if KeychainManager.shared.read(key: Keys.accessToken) != nil {
            authState = .loggedIn
        }
    }

    func sendOtp(email: String) async throws {
        guard let url = URL(string: "\(proxyBaseURL)/api/v1/auth/send-otp") else {
            throw AuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["email": email])
        let requestId = HTTPLogger.attachRequestId(&request)
        HTTPLogger.logRequest(request, requestId: requestId)

        let startTime = ContinuousClock.now
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        HTTPLogger.logResponse(data: data, response: httpResponse, requestId: requestId, startTime: startTime)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError("Failed to send OTP (\(httpResponse.statusCode)): \(body)")
        }

        authState = .otpSent
        Log.app.info("[Auth] OTP sent to \(email)")
    }

    func verifyOtp(email: String, code: String) async throws {
        guard let url = URL(string: "\(proxyBaseURL)/api/v1/auth/verify-otp") else {
            throw AuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["email": email, "code": code])
        let verifyRequestId = HTTPLogger.attachRequestId(&request)
        HTTPLogger.logRequest(request, requestId: verifyRequestId)

        let verifyStart = ContinuousClock.now
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        HTTPLogger.logResponse(data: data, response: httpResponse, requestId: verifyRequestId, startTime: verifyStart)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError("Verification failed (\(httpResponse.statusCode)): \(body)")
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        try storeTokens(access: tokenResponse.accessToken, refresh: tokenResponse.refreshToken, email: email)
        authState = .loggedIn

        // Switch to cloud processing now that the user is authenticated
        SettingsStorage.shared.transcriptionProvider = .cloud
        SettingsStorage.shared.meetingRealtimeTranscriptionEnabled = true

        Log.app.info("[Auth] Logged in as \(email), switched to cloud processing")
    }

    func refreshTokens() async throws {
        guard let refreshToken = KeychainManager.shared.read(key: Keys.refreshToken) else {
            throw AuthError.notAuthenticated
        }

        guard let url = URL(string: "\(proxyBaseURL)/api/v1/auth/refresh") else {
            throw AuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["refreshToken": refreshToken])
        let refreshRequestId = HTTPLogger.attachRequestId(&request)
        HTTPLogger.logRequest(request, requestId: refreshRequestId)

        let refreshStart = ContinuousClock.now
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        HTTPLogger.logResponse(data: data, response: httpResponse, requestId: refreshRequestId, startTime: refreshStart)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                clearTokens()
                throw AuthError.notAuthenticated
            }
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError("Token refresh failed (\(httpResponse.statusCode)): \(body)")
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        let email = userEmail ?? ""
        try storeTokens(access: tokenResponse.accessToken, refresh: tokenResponse.refreshToken, email: email)
        Log.app.info("[Auth] Tokens refreshed")
    }

    func logout() async {
        // Best-effort server logout
        if let refreshToken = KeychainManager.shared.read(key: Keys.refreshToken),
           let url = URL(string: "\(proxyBaseURL)/api/v1/auth/logout")
        {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(["refreshToken": refreshToken])

            if let accessToken = KeychainManager.shared.read(key: Keys.accessToken) {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }

            _ = try? await URLSession.shared.data(for: request)
        }

        clearTokens()

        // Switch to local providers since cloud requires auth
        SettingsStorage.shared.transcriptionProvider = .local
        SettingsStorage.shared.meetingRealtimeTranscriptionEnabled = false

        Log.app.info("[Auth] Logged out, switched to local provider")
    }

    // MARK: - Token Access

    /// Returns the current access token, auto-refreshing if expired.
    nonisolated func getAccessToken() async -> String? {
        guard let token = KeychainManager.shared.read(key: Keys.accessToken) else { return nil }

        if Self.isTokenExpired(token) {
            do {
                try await self.refreshTokens()
                return KeychainManager.shared.read(key: Keys.accessToken)
            } catch {
                Log.app.error("[Auth] Token refresh failed: \(error.localizedDescription)")
                return nil
            }
        }

        return token
    }

    /// Sets the Bearer auth header on a request.
    nonisolated func authenticatedRequest(_ request: inout URLRequest) async {
        guard let token = await getAccessToken() else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// Performs a URLSession request with automatic 401 retry (refreshes token once).
    nonisolated func performWithAuth(
        _ request: URLRequest,
        session: URLSession = .shared
    ) async throws -> (Data, HTTPURLResponse) {
        var authedRequest = request
        await authenticatedRequest(&authedRequest)
        let requestId = HTTPLogger.attachRequestId(&authedRequest)
        HTTPLogger.logRequest(authedRequest, requestId: requestId)

        let startTime = ContinuousClock.now
        let (data, response) = try await session.data(for: authedRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        HTTPLogger.logResponse(data: data, response: httpResponse, requestId: requestId, startTime: startTime)

        // Retry once on 401
        if httpResponse.statusCode == 401 {
            try await refreshTokens()

            var retryRequest = request
            await authenticatedRequest(&retryRequest)
            let retryRequestId = HTTPLogger.attachRequestId(&retryRequest)
            HTTPLogger.logRequest(retryRequest, requestId: retryRequestId)

            let retryStart = ContinuousClock.now
            let (retryData, retryResponse) = try await session.data(for: retryRequest)
            guard let retryHttpResponse = retryResponse as? HTTPURLResponse else {
                throw AuthError.invalidResponse
            }
            HTTPLogger.logResponse(data: retryData, response: retryHttpResponse, requestId: retryRequestId, startTime: retryStart)
            return (retryData, retryHttpResponse)
        }

        return (data, httpResponse)
    }

    // MARK: - Token Expiry Check

    /// Token format: `userId:timestamp:random:signature` (base64url-encoded segments separated by colons).
    /// Checks if 15 minutes have passed since the timestamp.
    private nonisolated static func isTokenExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ":")
        guard parts.count >= 2,
              let timestamp = TimeInterval(parts[1])
        else {
            // Can't parse — treat as expired to force refresh
            return true
        }

        let tokenDate = Date(timeIntervalSince1970: timestamp / 1000)
        let elapsed = Date().timeIntervalSince(tokenDate)
        // Refresh 1 minute before actual 15-min expiry
        return elapsed >= (14 * 60)
    }

    // MARK: - Keychain Helpers

    private func storeTokens(access: String, refresh: String, email: String) throws {
        try KeychainManager.shared.save(key: Keys.accessToken, value: access)
        try KeychainManager.shared.save(key: Keys.refreshToken, value: refresh)
        if !email.isEmpty {
            try KeychainManager.shared.save(key: Keys.userEmail, value: email)
        }
    }

    private func clearTokens() {
        KeychainManager.shared.delete(key: Keys.accessToken)
        KeychainManager.shared.delete(key: Keys.refreshToken)
        KeychainManager.shared.delete(key: Keys.userEmail)
        authState = .loggedOut
    }
}

// MARK: - Models

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
}

enum AuthError: LocalizedError {
    case invalidURL
    case invalidResponse
    case notAuthenticated
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid auth URL"
        case .invalidResponse:
            "Invalid server response"
        case .notAuthenticated:
            "Not authenticated — please log in"
        case let .serverError(message):
            message
        }
    }
}
