@testable import Diduny
import Testing

@Suite("PushToTalkService Hold Delay")
@MainActor
struct PushToTalkServiceTests {
    init() {
        SettingsStorage.shared.pushToTalkHoldEnabled = true
        SettingsStorage.shared.pushToTalkToggleEnabled = false
        SettingsStorage.shared.translationPushToTalkHoldEnabled = false
        SettingsStorage.shared.translationPushToTalkToggleEnabled = false
        SettingsStorage.shared.pushToTalkHoldStartDelaySeconds = 1.2
        SettingsStorage.shared.translationPushToTalkHoldStartDelaySeconds = 1.2
    }

    @Test("Short hold before threshold does not start or stop recording")
    func shortHoldBeforeThresholdDoesNotStart() async {
        let sut = PushToTalkService()
        sut.selectedKey = .rightShift
        sut.holdStartDelaySeconds = 0.5

        var starts = 0
        var stops = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }

        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        try? await Task.sleep(for: .milliseconds(200))
        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.2)
        try? await Task.sleep(for: .milliseconds(350))

        #expect(starts == 0)
        #expect(stops == 0)
    }

    @Test("Hold past threshold starts once and release stops once")
    func holdPastThresholdStartsAndReleaseStops() async {
        let sut = PushToTalkService()
        sut.selectedKey = .rightShift
        sut.holdStartDelaySeconds = 0.5

        var starts = 0
        var stops = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }

        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        try? await Task.sleep(for: .milliseconds(550))

        #expect(starts == 1)
        #expect(stops == 0)

        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.55)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(starts == 1)
        #expect(stops == 1)
    }

    @Test("Reset while hold is active preserves release stop")
    func resetHandsFreeModeDuringActiveHoldPreservesReleaseStop() async {
        let sut = PushToTalkService()
        sut.selectedKey = .rightShift
        sut.holdStartDelaySeconds = 0.5

        var starts = 0
        var stops = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }

        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        try? await Task.sleep(for: .milliseconds(550))

        sut.resetHandsFreeMode()
        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.6)

        #expect(starts == 1)
        #expect(stops == 1)
    }

    @Test("Hands-free toggle ignores hold delay")
    func handsFreeToggleIgnoresHoldDelay() async {
        let sut = PushToTalkService()
        sut.selectedKey = .rightShift
        sut.holdModeEnabled = false
        sut.toggleModeEnabled = true
        sut.toggleTapCount = 2
        sut.holdStartDelaySeconds = 1.0

        var toggles = 0
        var starts = 0
        sut.onToggle = { toggles += 1 }
        sut.onKeyDown = { starts += 1 }

        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.05)
        sut.processModifierKeyEvent(isPressed: true, eventTime: 0.1)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(toggles == 1)
        #expect(starts == 0)
    }

    @Test("Hold and toggle modes can be enabled together")
    func holdAndToggleModesCanBeEnabledTogether() async {
        let sut = PushToTalkService()
        sut.selectedKey = .rightShift
        sut.holdModeEnabled = true
        sut.toggleModeEnabled = true
        sut.toggleTapCount = 2
        sut.holdStartDelaySeconds = 0.5

        var starts = 0
        var stops = 0
        var toggles = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }
        sut.onToggle = { toggles += 1 }

        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.05)
        sut.processModifierKeyEvent(isPressed: true, eventTime: 0.1)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.15)
        try? await Task.sleep(for: .milliseconds(150))

        #expect(toggles == 1)
        #expect(starts == 0)
        #expect(stops == 0)

        sut.processModifierKeyEvent(isPressed: true, eventTime: 1.0)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 1.05)
        sut.processModifierKeyEvent(isPressed: true, eventTime: 1.1)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 1.15)
        try? await Task.sleep(for: .milliseconds(150))

        #expect(toggles == 2)
        #expect(starts == 0)

        sut.processModifierKeyEvent(isPressed: true, eventTime: 2.0)
        try? await Task.sleep(for: .milliseconds(550))
        sut.processModifierKeyEvent(isPressed: false, eventTime: 2.6)

        #expect(starts == 1)
        #expect(stops == 1)
    }

    @Test("Settings clamp hold start delay range")
    func settingsClampHoldStartDelayRange() {
        SettingsStorage.shared.pushToTalkHoldStartDelaySeconds = 0.05
        #expect(SettingsStorage.shared.pushToTalkHoldStartDelaySeconds == 0.5)

        SettingsStorage.shared.pushToTalkHoldStartDelaySeconds = 2.5
        #expect(SettingsStorage.shared.pushToTalkHoldStartDelaySeconds == 2.0)

        SettingsStorage.shared.translationPushToTalkHoldStartDelaySeconds = 0.55
        #expect(SettingsStorage.shared.translationPushToTalkHoldStartDelaySeconds == 0.6)
    }
}
