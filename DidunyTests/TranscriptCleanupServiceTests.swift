import Foundation
import Testing

@testable import Diduny

// MARK: - TranscriptCleanupService Unit Tests
//
// These tests cover the guard-clause logic of TranscriptCleanupService
// without making real network calls.  The happy-path (backend round-trip)
// is covered by integration / contract tests on the backend side.

@Suite("TranscriptCleanupService guard clauses")
struct TranscriptCleanupServiceTests {

    // MARK: - Empty input

    @Test("Empty string is returned unchanged without hitting the network")
    func emptyInputReturnedAsIs() async {
        // TranscriptCleanupService.shared skips the request for empty input.
        // Even if auth/network is present the result must be the unchanged string.
        let result = await TranscriptCleanupService.shared.clean("", fillerWords: [])
        #expect(result == "")
    }

    @Test("Whitespace-only input is returned unchanged")
    func whitespaceOnlyInputReturnedAsIs() async {
        let result = await TranscriptCleanupService.shared.clean("   \n\t  ", fillerWords: [])
        #expect(result == "   \n\t  ")
    }

    // MARK: - No auth session
    //
    // When AuthService.hasStoredSession == false the service must return rawText immediately.
    // We validate the observable effect (return value equals input) because we cannot easily
    // inject a mock auth service without refactoring the singleton.  The guard in
    // TranscriptCleanupService is `guard AuthService.hasStoredSession else { return rawText }`,
    // so on a test runner without Keychain credentials this path is always exercised.

    @Test("Without a stored session the service returns the raw text unchanged")
    func noSessionReturnsRawText() async {
        // In the test sandbox there is no stored Keychain token, so hasStoredSession == false.
        guard !AuthService.hasStoredSession else {
            // If CI somehow has a session, skip rather than fail.
            return
        }
        let input = "Hello world this is a test."
        let result = await TranscriptCleanupService.shared.clean(input, fillerWords: ["um", "uh"])
        #expect(result == input)
    }

    // MARK: - ClipboardService.preparedText interaction

    @Test(".cleaned behavior trims surrounding whitespace from the already-cleaned text")
    func preparedTextTrimsWhitespace() {
        let padded = "  Hello world  \n"
        let result = ClipboardService.preparedText(padded, behavior: .cleaned)
        #expect(result == "Hello world")
    }

    @Test(".cleaned behavior on already-trimmed text returns it unchanged")
    func preparedTextNoopOnTrimmedInput() {
        let input = "Hello world"
        let result = ClipboardService.preparedText(input, behavior: .cleaned)
        #expect(result == input)
    }

    @Test(".raw behavior returns text completely unchanged including surrounding whitespace")
    func preparedTextRawPreservesEverything() {
        let input = "  \nHello world\n  "
        let result = ClipboardService.preparedText(input, behavior: .raw)
        #expect(result == input)
    }

    @Test(".raw on empty string returns empty string")
    func preparedTextRawEmptyString() {
        #expect(ClipboardService.preparedText("", behavior: .raw) == "")
    }

    @Test(".cleaned on empty string returns empty string")
    func preparedTextCleanedEmptyString() {
        #expect(ClipboardService.preparedText("", behavior: .cleaned) == "")
    }

    // MARK: - Reachability default

    @Test("isReachable is true immediately after service init (optimistic default)")
    func isReachableDefaultsToTrue() {
        // The monitor starts as true so the first dictation after cold launch
        // is not blocked before NWPathMonitor fires its first update.
        #expect(TranscriptCleanupService.shared.isReachable == true)
    }
}
