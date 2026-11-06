@testable import Diduny
import Foundation
import Testing

/// "Stop, paste and send": registered only while dictation records, press count and switch.
@MainActor
final class ForceSubmitServiceTests {
    private let box = IsolatedSettings("ForceSubmitServiceTests")
    private let registrar = FakeHotkeyRegistrar()
    private let clock = ManualClock(10)
    private lazy var sut = ForceSubmitService(settings: box.settings, registrar: registrar, clock: clock)

    @Test("T5-FS-02 registered only while dictation records")
    func registeredOnlyWhileRecording() {
        #expect(!registrar.isEnabled(.forceSubmit))
        sut.activate {}
        #expect(registrar.isEnabled(.forceSubmit))
        #expect(sut.isActive)

        sut.deactivate()
        #expect(registrar.calls.last == .disable(.forceSubmit))
        #expect(!registrar.isEnabled(.forceSubmit))
    }

    @Test("T5-FS-03 switch off: activate registers nothing and a press does not arm")
    func switchOff() {
        box.settings.forceSubmitEnabled = false
        var triggers = 0
        sut.activate { triggers += 1 }
        registrar.fire(.forceSubmit)

        #expect(!registrar.isEnabled(.forceSubmit))
        #expect(!sut.isArmed)
        #expect(triggers == 0)
    }

    @Test("Count 1 arms on the first press and triggers once")
    func countOneArmsOnFirstPress() {
        var triggers = 0
        sut.activate { triggers += 1 }
        registrar.fire(.forceSubmit)
        registrar.fire(.forceSubmit)

        #expect(sut.isArmed)
        #expect(triggers == 1)
        #expect(sut.consumeArmed())
        #expect(!sut.consumeArmed())
    }

    @Test("T5-FS-04 press count 2")
    func pressCountTwo() {
        box.settings.forceSubmitPressCount = 2
        var triggers = 0
        sut.activate { triggers += 1 }

        registrar.fire(.forceSubmit)
        #expect(!sut.isArmed)
        clock.advance(by: 0.2)
        registrar.fire(.forceSubmit)
        #expect(sut.isArmed)
        #expect(triggers == 1)
    }

    @Test("Two presses too far apart do not arm 2x")
    func pressesOutsideWindowDoNotArm() {
        box.settings.forceSubmitPressCount = 2
        sut.activate {}
        registrar.fire(.forceSubmit)
        clock.advance(by: 0.4)
        registrar.fire(.forceSubmit)
        #expect(!sut.isArmed)
    }
}
