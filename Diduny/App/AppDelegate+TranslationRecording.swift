import AppKit
import Foundation

// MARK: - Translation Recording (EN <-> UK)

extension AppDelegate {
    @objc func toggleTranslationRecording() {
        Log.app.info("toggleTranslationRecording called, current state: \(self.appState.translationRecordingState)")
        Task {
            await self.performToggleTranslationRecording()
        }
    }

    func performToggleTranslationRecording() async {
        switch appState.translationRecordingState {
        case .idle:
            await startTranslationRecording()
        case .recording:
            await stopTranslationRecording()
        default:
            Log.app.info("Translation state is \(self.appState.translationRecordingState), ignoring toggle")
        }
    }

    func startTranslationRecordingIfIdle() async {
        guard appState.translationRecordingState == .idle else {
            Log.app.info("startTranslationRecordingIfIdle: Not idle, ignoring")
            return
        }
        await startTranslationRecording()
    }

    func stopTranslationRecordingIfRecording() async {
        guard appState.translationRecordingState == .recording else {
            Log.app.info("stopTranslationRecordingIfRecording: Not recording, ignoring")
            return
        }
        await stopTranslationRecording()
    }

    func startTranslationRecording() async {
        Log.app.info("startTranslationRecording: BEGIN")

        // Request microphone permission on-demand
        let micGranted = await PermissionManager.shared.ensureMicrophonePermission()
        appState.microphonePermissionGranted = micGranted

        guard micGranted else {
            Log.app.warning("startTranslationRecording: Microphone permission not granted")
            await MainActor.run {
                appState.errorMessage = "Microphone access required"
                appState.translationRecordingState = .error
                handleTranslationStateChange(.error)
            }
            return
        }

        guard let apiKey = KeychainManager.shared.getSonioxAPIKey(), !apiKey.isEmpty else {
            Log.app.warning("startTranslationRecording: No API key found")
            await MainActor.run {
                appState.errorMessage = "Please add your Soniox API key in Settings"
                appState.translationRecordingState = .error
                handleTranslationStateChange(.error)
            }
            return
        }
        Log.app.info("startTranslationRecording: API key found")

        // Determine device with fallback to system default
        var device: AudioDevice?

        if appState.useAutoDetect {
            Log.app.info("startTranslationRecording: Using auto-detect")
            await MainActor.run { appState.translationRecordingState = .processing }
            device = await audioDeviceManager.autoDetectBestDevice()
            Log.app.info("startTranslationRecording: Auto-detected device: \(device?.name ?? "none")")
        } else if let deviceID = appState.selectedDeviceID {
            // Refresh device list to ensure we have current state
            audioDeviceManager.refreshDevices()

            if audioDeviceManager.isDeviceAvailable(deviceID) {
                device = audioDeviceManager.device(for: deviceID)
                Log.app.info("startTranslationRecording: Using selected device: \(device?.name ?? "none")")
            } else {
                // Selected device is no longer available - fallback to system default
                Log.app.warning("startTranslationRecording: Selected device (ID: \(deviceID)) not available, falling back to default")
                device = audioDeviceManager.getCurrentDefaultDevice()
                Log.app.info("startTranslationRecording: Fallback to default device: \(device?.name ?? "none")")
            }
        } else {
            // No device selected - use system default
            Log.app.info("startTranslationRecording: No device selected, using system default")
            device = audioDeviceManager.getCurrentDefaultDevice()
        }

        // If still no device available, try last resort or show error
        if device == nil && !appState.useAutoDetect {
            if audioDeviceManager.availableDevices.isEmpty {
                Log.app.error("startTranslationRecording: No audio input devices available")
                await MainActor.run {
                    appState.errorMessage = "No microphone found. Please connect a microphone."
                    appState.translationRecordingState = .error
                    handleTranslationStateChange(.error)
                }
                return
            }
            // Last resort: pick first available device
            device = audioDeviceManager.availableDevices.first
            Log.app.info("startTranslationRecording: Using first available device: \(device?.name ?? "none")")
        }

        Log.app.info("startTranslationRecording: Setting state to recording")

        // Prevent App Nap during translation recording
        translationActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Translation recording in progress"
        )

        await MainActor.run {
            appState.translationRecordingState = .recording
            appState.translationRecordingStartTime = Date()
            handleTranslationStateChange(.recording)
        }

        do {
            Log.app.info("startTranslationRecording: Starting audio recording")
            try await audioRecorder.startRecording(device: device)
            Log.app.info("startTranslationRecording: Recording started successfully")
        } catch let error as AudioTimeoutError {
            // Audio hardware timed out - likely coreaudiod is unresponsive or device is unavailable
            Log.app.error("startTranslationRecording: TIMEOUT - \(error.localizedDescription)")

            // End App Nap prevention
            if let token = translationActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                translationActivityToken = nil
            }

            // Show specific error message for timeout
            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.translationRecordingState = .error
                appState.translationRecordingStartTime = nil
                handleTranslationStateChange(.error)
            }

            return
        } catch {
            // Handle any other errors during recording start
            Log.app.error("startTranslationRecording: ERROR - \(error.localizedDescription)")

            // End App Nap prevention
            if let token = translationActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                translationActivityToken = nil
            }

            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.translationRecordingState = .error
                appState.translationRecordingStartTime = nil
                handleTranslationStateChange(.error)
            }
            return
        }

        // Save recovery state in case of crash
        if let path = audioRecorder.currentRecordingPath {
            let state = RecoveryState(
                tempFilePath: path,
                startTime: Date(),
                recordingType: .translation
            )
            RecoveryStateManager.shared.saveState(state)
        }
    }

    func stopTranslationRecording() async {
        Log.app.info("stopTranslationRecording: BEGIN")

        await MainActor.run {
            appState.translationRecordingState = .processing
            handleTranslationStateChange(.processing)
        }

        do {
            Log.app.info("stopTranslationRecording: Stopping audio recorder")
            let audioData = try await audioRecorder.stopRecording()
            Log.app.info("stopTranslationRecording: Got audio data, size = \(audioData.count) bytes")

            guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                Log.app.error("stopTranslationRecording: No API key!")
                throw TranscriptionError.noAPIKey
            }

            Log.app.info("stopTranslationRecording: Calling translation service (EN <-> UK)")
            transcriptionService.apiKey = apiKey
            let text = try await transcriptionService.translateAndTranscribe(audioData: audioData)
            Log.app.info("stopTranslationRecording: Translation received: \(text.prefix(50))...")

            clipboardService.copy(text: text)
            Log.app.info("stopTranslationRecording: Text copied to clipboard")

            if SettingsStorage.shared.autoPaste {
                Log.app.info("stopTranslationRecording: Auto-pasting")
                do {
                    try await clipboardService.paste()
                } catch ClipboardError.accessibilityNotGranted {
                    Log.app.warning("stopTranslationRecording: Accessibility permission needed")
                    PermissionManager.shared.showPermissionAlert(for: .accessibility)
                } catch {
                    Log.app.error("stopTranslationRecording: Paste failed - \(error.localizedDescription)")
                }
            }

            // Update state to success IMMEDIATELY after text is available
            // This ensures the UI shows checkmark right when user can work with the text
            await MainActor.run {
                appState.lastTranscription = text
                appState.isEmptyTranscription = false
                appState.translationRecordingState = .success
                appState.translationRecordingStartTime = nil
                handleTranslationStateChange(.success)
            }
            Log.app.info("stopTranslationRecording: SUCCESS")

            // Optional operations run after state change (non-blocking for UI)
            if SettingsStorage.shared.playSoundOnCompletion {
                Log.app.info("stopTranslationRecording: Playing sound")
                NSSound(named: .init("Funk"))?.play()
            }

            // Clear recovery state on success
            RecoveryStateManager.shared.clearState()

        } catch {
            Log.app.error("stopTranslationRecording: ERROR - \(error.localizedDescription)")
            let isEmptyTranscription: Bool = {
                guard case .emptyTranscription = error as? TranscriptionError else { return false }
                return true
            }()
            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.isEmptyTranscription = isEmptyTranscription
                appState.translationRecordingState = .error
                appState.translationRecordingStartTime = nil
                handleTranslationStateChange(.error)
            }
        }

        // End App Nap prevention
        if let token = translationActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            translationActivityToken = nil
        }

        Log.app.info("stopTranslationRecording: END")
    }
}
