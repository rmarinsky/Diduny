import AppKit
import Testing

@testable import Diduny

@Suite("ForceSubmitPolicy")
struct ForceSubmitPolicyTests {
    @Test("Submits only when armed, auto-paste on, text present and paste succeeded")
    func submitsOnSuccessfulPaste() {
        #expect(ForceSubmitPolicy.shouldSubmit(armed: true, autoPaste: true, hasText: true, pasteSucceeded: true))
    }

    @Test("Does not submit when not armed")
    func notArmed() {
        #expect(!ForceSubmitPolicy.shouldSubmit(armed: false, autoPaste: true, hasText: true, pasteSucceeded: true))
    }

    @Test("Does not submit when auto-paste is off")
    func autoPasteOff() {
        #expect(!ForceSubmitPolicy.shouldSubmit(armed: true, autoPaste: false, hasText: true, pasteSucceeded: true))
    }

    @Test("Does not submit with empty text")
    func emptyText() {
        #expect(!ForceSubmitPolicy.shouldSubmit(armed: true, autoPaste: true, hasText: false, pasteSucceeded: true))
    }

    @Test("Does not submit when paste failed")
    func pasteFailed() {
        #expect(!ForceSubmitPolicy.shouldSubmit(armed: true, autoPaste: true, hasText: true, pasteSucceeded: false))
    }

    @Test("Submit key is always Command-Return")
    func submitKey() {
        #expect(ForceSubmitPolicy.submitKeyCode == 36)
        #expect(ForceSubmitPolicy.submitFlags == .maskCommand)
    }

    @Test("Armed flag is consumed once")
    @MainActor
    func consumeOnce() {
        let sut = ForceSubmitService.shared
        sut.disarm()
        #expect(!sut.consumeArmed())
    }
}
