import AppKit
import Foundation

// MARK: - Hotkey & Push to Talk

extension AppDelegate {
    func setupHotkeys() {
        // Register all hotkeys - KeyboardShortcuts handles storage automatically
        hotkeyService.registerRecordingHotkey { [weak self] in
            self?.toggleRecording()
        }

        hotkeyService.registerTranslationHotkey { [weak self] in
            self?.toggleTranslationRecording()
        }

        hotkeyService.registerHistoryPaletteHotkey {
            HistoryPaletteWindowController.shared.toggle()
        }

        hotkeyService.registerTranslateSelectedTextHotkey {
            Task {
                do {
                    let text = try await ClipboardService.shared.captureSelectedText()
                    await MainActor.run {
                        TextTranslationWindowController.shared.showWindow(sourceText: text)
                    }
                } catch {
                    Log.app.error("[TranslateSelected] Failed to capture text: \(error)")
                }
            }
        }
    }

    func setupPushToTalk() {
        let key = SettingsStorage.shared.pushToTalkKey
        pushToTalkService.selectedKey = key
        pushToTalkService.holdModeEnabled = SettingsStorage.shared.pushToTalkHoldEnabled
        pushToTalkService.toggleModeEnabled = SettingsStorage.shared.pushToTalkToggleEnabled
        pushToTalkService.toggleTapCount = SettingsStorage.shared.pushToTalkToggleTapCount
        pushToTalkService.holdStartDelaySeconds = SettingsStorage.shared.pushToTalkHoldStartDelaySeconds

        pushToTalkService.onKeyDown = { [weak self] in
            guard let self else { return }
            Task {
                await self.startRecordingIfIdle()
            }
        }

        pushToTalkService.onKeyUp = { [weak self] in
            guard let self else { return }
            Task {
                await self.stopRecordingIfRecording()
            }
        }

        // Toggle handler for hands-free mode
        pushToTalkService.onToggle = { [weak self] in
            guard let self else { return }
            Task {
                await self.performToggleRecording()
            }
        }

        if shouldMonitorModifierKey(key, hold: pushToTalkService.holdModeEnabled, toggle: pushToTalkService.toggleModeEnabled) {
            pushToTalkService.start()
        }
    }

    @objc func pushToTalkKeyChanged(_ notification: Notification) {
        guard let key = notification.object as? PushToTalkKey else { return }
        Log.app.info("Push-to-talk key changed to: \(key.displayName)")

        pushToTalkService.stop()
        pushToTalkService.selectedKey = key
        pushToTalkService.holdModeEnabled = SettingsStorage.shared.pushToTalkHoldEnabled
        pushToTalkService.toggleModeEnabled = SettingsStorage.shared.pushToTalkToggleEnabled
        pushToTalkService.toggleTapCount = SettingsStorage.shared.pushToTalkToggleTapCount
        pushToTalkService.holdStartDelaySeconds = SettingsStorage.shared.pushToTalkHoldStartDelaySeconds

        if shouldMonitorModifierKey(key, hold: pushToTalkService.holdModeEnabled, toggle: pushToTalkService.toggleModeEnabled) {
            pushToTalkService.start()
        }
    }

    @objc func pushToTalkModeChanged(_: Notification) {
        pushToTalkService.stop()
        pushToTalkService.holdModeEnabled = SettingsStorage.shared.pushToTalkHoldEnabled
        pushToTalkService.toggleModeEnabled = SettingsStorage.shared.pushToTalkToggleEnabled
        pushToTalkService.toggleTapCount = SettingsStorage.shared.pushToTalkToggleTapCount
        pushToTalkService.resetHandsFreeMode()

        let key = pushToTalkService.selectedKey
        if shouldMonitorModifierKey(key, hold: pushToTalkService.holdModeEnabled, toggle: pushToTalkService.toggleModeEnabled) {
            pushToTalkService.start()
        }

        Log.app.info(
            "Dictation modifier modes changed: hold=\(self.pushToTalkService.holdModeEnabled, privacy: .public) toggle=\(self.pushToTalkService.toggleModeEnabled, privacy: .public)"
        )
    }

    @objc func pushToTalkTapCountChanged(_ notification: Notification) {
        guard let tapCount = notification.object as? Int else { return }
        pushToTalkService.toggleTapCount = tapCount
        pushToTalkService.resetHandsFreeMode()
        Log.app.info("Dictation modifier tap count changed to: \(tapCount)x")
    }

    @objc func pushToTalkHoldStartDelayChanged(_ notification: Notification) {
        guard let delay = notification.object as? TimeInterval else { return }
        pushToTalkService.holdStartDelaySeconds = delay
        pushToTalkService.resetHandsFreeMode()
        Log.app.info("Dictation modifier hold delay changed to: \(String(format: "%.1f", delay))s")
    }

    // MARK: - Translation Push to Talk

    func setupTranslationPushToTalk() {
        let key = SettingsStorage.shared.translationPushToTalkKey
        translationPushToTalkService.selectedKey = key
        translationPushToTalkService.holdModeEnabled = SettingsStorage.shared.translationPushToTalkHoldEnabled
        translationPushToTalkService.toggleModeEnabled = SettingsStorage.shared.translationPushToTalkToggleEnabled
        translationPushToTalkService.toggleTapCount = SettingsStorage.shared.translationPushToTalkToggleTapCount
        translationPushToTalkService.holdStartDelaySeconds =
            SettingsStorage.shared.translationPushToTalkHoldStartDelaySeconds

        translationPushToTalkService.onKeyDown = { [weak self] in
            guard let self else { return }
            Task {
                await self.startTranslationRecordingIfIdle()
            }
        }

        translationPushToTalkService.onKeyUp = { [weak self] in
            guard let self else { return }
            Task {
                await self.stopTranslationRecordingIfRecording()
            }
        }

        // Toggle handler for hands-free mode
        translationPushToTalkService.onToggle = { [weak self] in
            guard let self else { return }
            Task {
                await self.performToggleTranslationRecording()
            }
        }

        if shouldMonitorModifierKey(
            key,
            hold: translationPushToTalkService.holdModeEnabled,
            toggle: translationPushToTalkService.toggleModeEnabled
        ) {
            translationPushToTalkService.start()
        }
    }

    @objc func translationPushToTalkKeyChanged(_ notification: Notification) {
        guard let key = notification.object as? PushToTalkKey else { return }
        Log.app.info("Translation push-to-talk key changed to: \(key.displayName)")

        translationPushToTalkService.stop()
        translationPushToTalkService.selectedKey = key
        translationPushToTalkService.holdModeEnabled = SettingsStorage.shared.translationPushToTalkHoldEnabled
        translationPushToTalkService.toggleModeEnabled = SettingsStorage.shared.translationPushToTalkToggleEnabled
        translationPushToTalkService.toggleTapCount = SettingsStorage.shared.translationPushToTalkToggleTapCount
        translationPushToTalkService.holdStartDelaySeconds =
            SettingsStorage.shared.translationPushToTalkHoldStartDelaySeconds

        if shouldMonitorModifierKey(
            key,
            hold: translationPushToTalkService.holdModeEnabled,
            toggle: translationPushToTalkService.toggleModeEnabled
        ) {
            translationPushToTalkService.start()
        }
    }

    @objc func translationPushToTalkModeChanged(_: Notification) {
        translationPushToTalkService.stop()
        translationPushToTalkService.holdModeEnabled = SettingsStorage.shared.translationPushToTalkHoldEnabled
        translationPushToTalkService.toggleModeEnabled = SettingsStorage.shared.translationPushToTalkToggleEnabled
        translationPushToTalkService.toggleTapCount = SettingsStorage.shared.translationPushToTalkToggleTapCount
        translationPushToTalkService.resetHandsFreeMode()

        let key = translationPushToTalkService.selectedKey
        if shouldMonitorModifierKey(
            key,
            hold: translationPushToTalkService.holdModeEnabled,
            toggle: translationPushToTalkService.toggleModeEnabled
        ) {
            translationPushToTalkService.start()
        }

        Log.app.info(
            "Translation modifier modes changed: hold=\(self.translationPushToTalkService.holdModeEnabled, privacy: .public) toggle=\(self.translationPushToTalkService.toggleModeEnabled, privacy: .public)"
        )
    }

    @objc func translationPushToTalkTapCountChanged(_ notification: Notification) {
        guard let tapCount = notification.object as? Int else { return }
        translationPushToTalkService.toggleTapCount = tapCount
        translationPushToTalkService.resetHandsFreeMode()
        Log.app.info("Translation modifier tap count changed to: \(tapCount)x")
    }

    @objc func translationPushToTalkHoldStartDelayChanged(_ notification: Notification) {
        guard let delay = notification.object as? TimeInterval else { return }
        translationPushToTalkService.holdStartDelaySeconds = delay
        translationPushToTalkService.resetHandsFreeMode()
        Log.app.info("Translation modifier hold delay changed to: \(String(format: "%.1f", delay))s")
    }

    private func shouldMonitorModifierKey(_ key: PushToTalkKey, hold: Bool, toggle: Bool) -> Bool {
        key != .none && (hold || toggle)
    }

}
