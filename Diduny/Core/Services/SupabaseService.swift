import Foundation
import Supabase
import os

/// Singleton wrapper around the Supabase SDK client.
///
/// Ownership rule: SupabaseService owns the SupabaseClient and its Keychain session.
/// AuthService delegates all Supabase Auth calls here. Cloud services call
/// `currentAccessToken` to get the bearer token.
final class SupabaseService: @unchecked Sendable {
    static let shared = SupabaseService()

    // MARK: - Constants

    /// Publishable / anon key — safe to embed in the binary (Row Level Security enforces data
    /// isolation at the DB level). Do NOT embed the secret key here.
    private static let supabaseURL = URL(string: "https://oplmqfsttetsosglilkb.supabase.co")!
    private static let supabaseAnonKey = "sb_publishable_kLAVgHi1AGvXF_ZTdAdaEA_Yyfgvv_o"

    // MARK: - Client

    /// The shared SupabaseClient. The SDK persists the session automatically in the macOS Keychain
    /// and refreshes the access token before it expires.
    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: Self.supabaseURL,
            supabaseKey: Self.supabaseAnonKey
        )
    }

    // MARK: - Session Accessors

    /// Returns the current access token from the cached Supabase session, or nil when
    /// not authenticated.
    var currentAccessToken: String? {
        get async {
            do {
                return try await client.auth.session.accessToken
            } catch {
                return nil
            }
        }
    }

    /// Returns the current session, or nil when not authenticated.
    var currentSession: Session? {
        get async {
            return try? await client.auth.session
        }
    }

    // MARK: - Auth Actions

    /// Sends a magic-link / email OTP. Supabase delivers the email via its own SMTP.
    func signInWithOTP(email: String) async throws {
        try await client.auth.signInWithOTP(email: email)
        Log.app.info("[Supabase] OTP sent to \(email)")
    }

    /// Verifies the 6-digit OTP code received via email.
    /// On success the SDK stores a Session in the macOS Keychain automatically.
    func verifyOTP(email: String, token: String) async throws {
        try await client.auth.verifyOTP(
            email: email,
            token: token,
            type: .email
        )
        Log.app.info("[Supabase] OTP verified, session created")
    }

    /// Signs the user out. Invalidates the remote session and clears the local Keychain entry.
    func signOut() async throws {
        try await client.auth.signOut()
        Log.app.info("[Supabase] Signed out")
    }

    /// Explicitly refreshes the access token.
    /// Under normal circumstances the SDK does this automatically; call this only after
    /// a WS reconnect returns 401 (ADR-0004 edge case).
    @discardableResult
    func refreshSession() async throws -> Session {
        let session = try await client.auth.refreshSession()
        Log.app.info("[Supabase] Session refreshed")
        return session
    }

    // MARK: - Auth State Changes

    /// Subscribes to Supabase Auth state changes.
    /// The returned Task should be retained for the lifetime of the observer.
    func onAuthStateChange(_ handler: @escaping (AuthChangeEvent, Session?) -> Void) -> Task<Void, Never> {
        Task {
            for await (event, session) in await client.auth.authStateChanges {
                handler(event, session)
            }
        }
    }
}
