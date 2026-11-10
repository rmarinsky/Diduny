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

        hotkeyService.registerMeetingHotkey { [weak self] in
            self?.toggleMeetingRecording()
        }

        hotkeyService.registerMeetingTranslationHotkey { [weak self] in
            self?.toggleMeetingTranslationRecording()
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

        // A Shortcuts row switch: off keeps the keys and disables the name; on enables it again.
        NotificationCenter.default.addObserver(forName: .shortcutSwitchesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkeyService.refreshSwitches() }
        }
    }

    func setupPushToTalk() {
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

        PushToTalkConfigurator.apply(PushToTalkConfigurator.dictation(.shared), to: pushToTalkService)
    }

    @objc func pushToTalkKeyChanged(_ notification: Notification) {
        guard let key = notification.object as? PushToTalkKey else { return }
        Log.app.info("Push-to-talk key changed to: \(key.displayName)")
        PushToTalkConfigurator.apply(PushToTalkConfigurator.dictation(.shared).with(key: key), to: pushToTalkService)
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

    // MARK: - In-place Selection Translation (double-tap ⌥⌘)

    func setupInplaceTranslation() {
        inplaceTranslationMonitor.onTrigger = {
            Task { @MainActor in
                await InplaceTranslationService.shared.run()
            }
        }
        refreshInplaceTranslationMonitor()

        // The switch and both push-to-talk configs decide whether the monitor runs.
        let names: [Notification.Name] = [
            .inplaceTranslationSettingsChanged,
            .pushToTalkKeyChanged, .pushToTalkModeChanged,
            .translationPushToTalkKeyChanged, .translationPushToTalkModeChanged
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshInplaceTranslationMonitor() }
            }
        }
    }

    private func refreshInplaceTranslationMonitor() {
        let settings = SettingsStorage.shared
        inplaceTranslationMonitor.reservedKeys = settings.inplaceTranslationReservedKeys
        inplaceTranslationMonitor.configure(
            shortcut: settings.inplaceTranslationShortcut,
            pressCount: settings.inplaceTranslationPressCount
        )
        if settings.inplaceTranslationActive {
            inplaceTranslationMonitor.start()
        } else {
            inplaceTranslationMonitor.stop()
        }
    }

    // MARK: - Translation Push to Talk

    func setupTranslationPushToTalk() {
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

        PushToTalkConfigurator.apply(PushToTalkConfigurator.translation(.shared), to: translationPushToTalkService)
    }

    @objc func translationPushToTalkKeyChanged(_ notification: Notification) {
        guard let key = notification.object as? PushToTalkKey else { return }
        Log.app.info("Translation push-to-talk key changed to: \(key.displayName)")
        PushToTalkConfigurator.apply(
            PushToTalkConfigurator.translation(.shared).with(key: key),
            to: translationPushToTalkService
        )
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
