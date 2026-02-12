import Foundation

// MARK: - Hotkey & Push to Talk

extension AppDelegate {
    func setupHotkeys() {
        // Register all hotkeys - KeyboardShortcuts handles storage automatically
        hotkeyService.registerRecordingHotkey { [weak self] in
            self?.toggleRecording()
        }

        hotkeyService.registerMeetingHotkey { [weak self] in
            self?.toggleMeetingRecording()
        }

        hotkeyService.registerTranslationHotkey { [weak self] in
            self?.toggleTranslationRecording()
        }

        hotkeyService.registerHistoryPaletteHotkey {
            HistoryPaletteWindowController.shared.toggle()
        }
    }

    func setupPushToTalk() {
        let key = SettingsStorage.shared.pushToTalkKey
        pushToTalkService.selectedKey = key

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

        if key != .none {
            pushToTalkService.start()
        }
    }

    @objc func pushToTalkKeyChanged(_ notification: Notification) {
        guard let key = notification.object as? PushToTalkKey else { return }
        Log.app.info("Push-to-talk key changed to: \(key.displayName)")

        pushToTalkService.stop()
        pushToTalkService.selectedKey = key

        if key != .none {
            pushToTalkService.start()
        }
    }

    // MARK: - Translation Push to Talk

    func setupTranslationPushToTalk() {
        let key = SettingsStorage.shared.translationPushToTalkKey
        translationPushToTalkService.selectedKey = key

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

        if key != .none {
            translationPushToTalkService.start()
        }
    }

    @objc func translationPushToTalkKeyChanged(_ notification: Notification) {
        guard let key = notification.object as? PushToTalkKey else { return }
        Log.app.info("Translation push-to-talk key changed to: \(key.displayName)")

        translationPushToTalkService.stop()
        translationPushToTalkService.selectedKey = key

        if key != .none {
            translationPushToTalkService.start()
        }
    }
}
