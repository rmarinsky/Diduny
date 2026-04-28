import Foundation
import Supabase
import os

/// Diduny auth façade backed by the Supabase Auth SDK.
///
/// Public interface is intentionally kept identical to the previous custom-auth
/// version so that AppDelegate and UI components require only local call-site
/// changes (OTP code length: 6, not 8).
///
/// Session Keychain storage and token rotation are managed entirely by the
/// supabase-swift SDK — do not duplicate them here.
@Observable
@MainActor
final class AuthService {
    static let shared = AuthService()

    /// True when the SDK has a cached session (does not validate expiry —
    /// the SDK auto-refreshes before the token expires).
    nonisolated static var hasStoredSession: Bool {
        // The SDK stores the session under a deterministic Keychain key. We
        // cannot call async APIs here (nonisolated static), so we rely on
        // UserDefaults as a cheap session-presence flag that AuthService keeps
        // in sync via onAuthStateChange.
        UserDefaults.standard.bool(forKey: "_diduny_supabase_session_present")
    }

    // MARK: - State

    enum AuthState {
        case loggedOut
        case otpSent
        case loggedIn
    }

    private(set) var authState: AuthState = .loggedOut

    var isLoggedIn: Bool {
        authState == .loggedIn
    }

    var userEmail: String? {
        _cachedEmail
    }

    // Cached from the session so callers that need a sync answer get one.
    private var _cachedEmail: String?

    // Retained for the lifetime of AuthService.
    private var authStateObserverTask: Task<Void, Never>?

    private var supabase: SupabaseService { SupabaseService.shared }

    private init() {
        // Eagerly restore session state from SDK cache.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let session = await supabase.currentSession {
                self._cachedEmail = session.user.email
                self.authState = .loggedIn
                Self.setSessionPresent(true)
            }
            self.startAuthStateObserver()
        }
    }

    // MARK: - Auth State Observer

    private func startAuthStateObserver() {
        authStateObserverTask?.cancel()
        authStateObserverTask = supabase.onAuthStateChange { [weak self] event, session in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event {
                case .signedIn, .tokenRefreshed, .userUpdated:
                    self._cachedEmail = session?.user.email
                    self.authState = .loggedIn
                    Self.setSessionPresent(true)
                    Log.app.info("[Auth] State → loggedIn (event: \(String(describing: event)))")
                case .signedOut, .userDeleted:
                    self._cachedEmail = nil
                    self.authState = .loggedOut
                    Self.setSessionPresent(false)
                    Log.app.info("[Auth] State → loggedOut (event: \(String(describing: event)))")
                default:
                    break
                }
            }
        }
    }

    // MARK: - OTP Flow

    /// Sends a 6-digit OTP email via Supabase Auth (Supabase handles delivery).
    func sendOtp(email: String) async throws {
        try await supabase.signInWithOTP(email: email)
        authState = .otpSent
    }

    /// Verifies the 6-digit OTP code from the email.
    /// On success the SDK stores a Session and authState transitions to .loggedIn
    /// via the auth-state observer.
    func verifyOtp(email: String, code: String) async throws {
        try await supabase.verifyOTP(email: email, token: code)
        // authState is updated by startAuthStateObserver → .signedIn event.
    }

    // MARK: - OTP Cancellation

    /// Cancels an in-progress OTP flow without touching the server.
    /// No Supabase session exists at this point, so no revocation is needed.
    func cancelOtpFlow() {
        authState = .loggedOut
    }

    // MARK: - Sign Out

    func logout() async {
        do {
            try await supabase.signOut()
            // authState updated via observer.
        } catch {
            // Best-effort: if sign-out RPC fails (offline), clear local state anyway.
            Log.app.warning("[Auth] Sign-out RPC failed: \(error.localizedDescription) — clearing local state")
            authState = .loggedOut
            _cachedEmail = nil
            Self.setSessionPresent(false)
        }
    }

    // MARK: - Token Access

    /// Returns the current Supabase access token, letting the SDK refresh it if needed.
    nonisolated func getAccessToken() async -> String? {
        await supabase.currentAccessToken
    }

    /// Attaches `Authorization: Bearer <token>` to a URLRequest.
    nonisolated func authenticatedRequest(_ request: inout URLRequest) async {
        guard let token = await getAccessToken() else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// Performs a URLSession request with automatic 401 retry.
    /// On 401 the SDK's `refreshSession()` is called once, then the request is retried.
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

        guard httpResponse.statusCode == 401 else {
            return (data, httpResponse)
        }

        // 401 → refresh session once, then retry.
        Log.app.info("[Auth] 401 received — refreshing Supabase session")
        do {
            try await SupabaseService.shared.refreshSession()
        } catch {
            Log.app.error("[Auth] Session refresh failed: \(error.localizedDescription)")
            throw AuthError.notAuthenticated
        }

        var retryRequest = request
        await authenticatedRequest(&retryRequest)
        let retryId = HTTPLogger.attachRequestId(&retryRequest)
        HTTPLogger.logRequest(retryRequest, requestId: retryId)

        let retryStart = ContinuousClock.now
        let (retryData, retryResponse) = try await session.data(for: retryRequest)
        guard let retryHTTP = retryResponse as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        HTTPLogger.logResponse(data: retryData, response: retryHTTP, requestId: retryId, startTime: retryStart)
        return (retryData, retryHTTP)
    }

    // MARK: - Refresh (kept for CloudRealtimeService ADR-0004 reconnect path)

    /// Explicit session refresh — used by CloudRealtimeService when WS upgrade
    /// returns 401 after a network blip (ADR-0004 edge case: silent refresh, 1 retry).
    func refreshTokens() async throws {
        do {
            try await supabase.refreshSession()
        } catch {
            // If refresh itself fails, the user is effectively signed out.
            authState = .loggedOut
            _cachedEmail = nil
            Self.setSessionPresent(false)
            throw AuthError.notAuthenticated
        }
    }

    // MARK: - Private Helpers

    private static func setSessionPresent(_ present: Bool) {
        UserDefaults.standard.set(present, forKey: "_diduny_supabase_session_present")
    }
}

// MARK: - Error Type

enum AuthError: LocalizedError {
    case invalidURL
    case invalidResponse
    case notAuthenticated
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid auth URL"
        case .invalidResponse: "Invalid server response"
        case .notAuthenticated: "Not authenticated — please log in"
        case let .serverError(message): message
        }
    }
}
