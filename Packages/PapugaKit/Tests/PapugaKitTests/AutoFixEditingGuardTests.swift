import Carbon.HIToolbox
import XCTest
@testable import PapugaKit

final class AutoFixEditingGuardTests: XCTestCase {
    func test_backspaceWithEmptyBufferSuppressesOnlyTheNextToken() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteBackspace(bufferWasEmpty: true, enabled: true)

        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))
        guardrail.noteBoundary()
        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_backspaceInsideCurrentBufferDoesNotSuppress() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteBackspace(bufferWasEmpty: false, enabled: true)

        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_navigationKeySuppressesNextToken() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteResetKey(UInt16(kVK_LeftArrow), enabled: true)

        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))
    }

    func test_escapeDoesNotSuppress() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteResetKey(UInt16(kVK_Escape), enabled: true)

        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_resetClearsCurrentSuppression() {
        var guardrail = AutoFixEditingGuard()
        guardrail.noteEditingStarted()
        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))

        guardrail.reset()

        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_disabledGuardNeverSuppresses() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteBackspace(bufferWasEmpty: true, enabled: false)
        guardrail.noteResetKey(UInt16(kVK_LeftArrow), enabled: false)

        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_shouldSuppressHonorsEnabledFlag() {
        var guardrail = AutoFixEditingGuard()
        guardrail.noteEditingStarted()

        XCTAssertFalse(guardrail.shouldSuppress(enabled: false))
        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))
    }

    func test_clickSuppressionSuppressesCurrentTokenOnly() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteClickSuppression()
        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))

        // After the first word boundary, the next token is evaluated normally.
        guardrail.noteBoundary()
        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }

    func test_editingStartedClearsAfterFirstBoundary() {
        var guardrail = AutoFixEditingGuard()

        guardrail.noteEditingStarted()
        XCTAssertTrue(guardrail.shouldSuppress(enabled: true))

        guardrail.noteBoundary()
        XCTAssertFalse(guardrail.shouldSuppress(enabled: true))
    }
}
