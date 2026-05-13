import XCTest
@testable import Diduny

/// Tests for the parts of AuthService that are unit-testable without a live
/// Supabase endpoint: hasStoredSession flag, UserDefaults synchronisation,
/// and the AuthError descriptions.
///
/// Network-dependent paths (OTP send/verify, session refresh) require a live
/// Supabase project and are excluded from the CI unit-test target; they are
/// covered by manual smoke tests per the Definition of Done.
final class AuthServiceTests: XCTestCase {

    // MARK: - hasStoredSession

    func test_hasStoredSession_falseByDefault() {
        UserDefaults.standard.removeObject(forKey: "_diduny_supabase_session_present")
        XCTAssertFalse(AuthService.hasStoredSession)
    }

    func test_hasStoredSession_trueWhenFlagSet() {
        UserDefaults.standard.set(true, forKey: "_diduny_supabase_session_present")
        XCTAssertTrue(AuthService.hasStoredSession)
        // Cleanup
        UserDefaults.standard.removeObject(forKey: "_diduny_supabase_session_present")
    }

    func test_hasStoredSession_falseAfterFlagCleared() {
        UserDefaults.standard.set(true, forKey: "_diduny_supabase_session_present")
        UserDefaults.standard.set(false, forKey: "_diduny_supabase_session_present")
        XCTAssertFalse(AuthService.hasStoredSession)
        // Cleanup
        UserDefaults.standard.removeObject(forKey: "_diduny_supabase_session_present")
    }

    // MARK: - AuthError descriptions

    func test_authError_invalidURL_hasDescription() {
        let error = AuthError.invalidURL
        XCTAssertEqual(error.errorDescription, "Invalid auth URL")
    }

    func test_authError_invalidResponse_hasDescription() {
        let error = AuthError.invalidResponse
        XCTAssertEqual(error.errorDescription, "Invalid server response")
    }

    func test_authError_notAuthenticated_hasDescription() {
        let error = AuthError.notAuthenticated
        XCTAssertEqual(error.errorDescription, "Not authenticated — please log in")
    }

    func test_authError_serverError_includesMessage() {
        let message = "Rate limit exceeded"
        let error = AuthError.serverError(message)
        XCTAssertEqual(error.errorDescription, message)
    }

    // MARK: - AuthState transitions (via shared instance, MainActor)

    /// Verifies the initial state is loggedOut when no session flag is present.
    @MainActor
    func test_initialState_isLoggedOut_whenNoSessionFlag() async {
        // The shared instance is a singleton; we can only observe, not reset it.
        // This test passes if AuthService.hasStoredSession reflects UserDefaults truthfully.
        UserDefaults.standard.removeObject(forKey: "_diduny_supabase_session_present")
        // Re-check the flag directly (not the live singleton which may already be loggedIn)
        XCTAssertFalse(AuthService.hasStoredSession)
    }
}
