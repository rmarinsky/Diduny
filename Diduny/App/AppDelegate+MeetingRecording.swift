import AppKit
import Foundation

// MARK: - Meeting Recording

extension AppDelegate {
    @objc func toggleMeetingRecording() {
        Log.app.info("toggleMeetingRecording called, current state: \(self.appState.meetingRecordingState)")
        Task {
            await self.performToggleMeetingRecording()
        }
    }

    func performToggleMeetingRecording() async {
        switch appState.meetingRecordingState {
        case .idle:
            await startMeetingRecording()
        case .recording:
            await stopMeetingRecording()
        case .processing:
            Log.app.info("Meeting state is processing, canceling...")
            await cancelMeetingRecording()
        default:
            Log.app.info("Meeting state is \(self.appState.meetingRecordingState), ignoring toggle")
        }
    }

    @available(macOS 13.0, *)
    func cancelMeetingRecording() async {
        Log.app.info("cancelMeetingRecording: BEGIN")

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Disconnect real-time transcription (if active)
        if appState.liveTranscriptStore != nil {
            await realtimeTranscriptionService.disconnect()
            meetingRecorderService.onRealtimeAudioData = nil
        }

        // Cancel meeting recorder
        await meetingRecorderService.cancelRecording()

        // Mark transcript as inactive but keep window open for review
        await MainActor.run {
            appState.liveTranscriptStore?.isActive = false
            appState.liveTranscriptStore = nil
        }

        // End App Nap prevention
        if let token = meetingActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            meetingActivityToken = nil
        }

        // Clear recovery state
        RecoveryStateManager.shared.clearState()

        // Reset state to idle
        await MainActor.run {
            appState.meetingRecordingState = .idle
            appState.meetingRecordingStartTime = nil
            handleMeetingStateChange(.idle)
        }

        Log.app.info("cancelMeetingRecording: END")
    }

    func startMeetingRecording() async {
        Log.app.info("startMeetingRecording: BEGIN")

        guard canStartRecording(kind: .meeting) else {
            Log.app.info("startMeetingRecording: blocked by another active recording mode")
            return
        }

        guard #available(macOS 13.0, *) else {
            Log.app.warning("Meeting recording requires macOS 13.0+")
            await MainActor.run {
                appState.errorMessage = "Meeting recording requires macOS 13.0 or later"
                appState.meetingRecordingState = .error
                handleMeetingStateChange(.error)
            }
            return
        }

        // Request screen capture permission on-demand
        let hasPermission = await PermissionManager.shared.ensureScreenRecordingPermission()
        appState.screenCapturePermissionGranted = hasPermission

        guard hasPermission else {
            Log.app.warning("Screen capture permission not granted")
            await MainActor.run {
                appState.errorMessage = "Screen recording permission required for meeting capture"
                appState.meetingRecordingState = .error
                handleMeetingStateChange(.error)
            }
            return
        }

        // API key is optional — recording works without it, but real-time transcription requires it
        let apiKey = KeychainManager.shared.getSonioxAPIKey()
        let hasApiKey = apiKey != nil && !apiKey!.isEmpty

        // Prevent App Nap during meeting recording
        meetingActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Meeting recording in progress"
        )

        // Show processing state while initializing (before we confirm it works)
        await MainActor.run {
            appState.meetingRecordingState = .processing
            handleMeetingStateChange(.processing)
        }

        do {
            meetingRecorderService.audioSource = SettingsStorage.shared.meetingAudioSource
            meetingRecorderService.onRealtimeAudioData = nil

            // Set microphone device for mixed recording
            if let deviceID = appState.selectedDeviceID {
                meetingRecorderService.microphoneDevice = audioDeviceManager.device(for: deviceID)
            } else {
                meetingRecorderService.microphoneDevice = audioDeviceManager.getCurrentDefaultDevice()
            }

            try await meetingRecorderService.startRecording()
            Log.app.info("Meeting recording started")

            // Setup real-time transcription only if API key is available
            var store: LiveTranscriptStore?
            if hasApiKey, let key = apiKey {
                store = await setupRealtimeTranscription(apiKey: key)
            } else {
                Log.app.info("No API key — recording audio only, no real-time transcription")
            }

            // Only set recording state AFTER confirmed working
            await MainActor.run {
                appState.meetingRecordingState = .recording
                appState.meetingRecordingStartTime = Date()
                appState.liveTranscriptStore = store
                handleMeetingStateChange(.recording)
            }

            // Show transcript window only if we have real-time transcription
            if let store {
                await MainActor.run {
                    TranscriptionWindowController.shared.showWindow(store: store)
                }
            }

            // Activate escape cancel handler
            await MainActor.run {
                setupMeetingEscapeCancelHandler()
            }

            // Activate chapter bookmark hotkey
            await MainActor.run {
                appState.meetingChapters = []
                hotkeyService.registerChapterHotkey { [weak self] in
                    self?.addMeetingChapter()
                }
            }

            // Save recovery state in case of crash
            if let path = meetingRecorderService.currentRecordingPath {
                let state = RecoveryState(
                    tempFilePath: path,
                    startTime: Date(),
                    recordingType: .meeting
                )
                RecoveryStateManager.shared.saveState(state)
            }
        } catch {
            Log.app.error("Meeting recording failed: \(error)")

            // End App Nap prevention on failed start
            if let token = meetingActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                meetingActivityToken = nil
            }

            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.meetingRecordingState = .error
                handleMeetingStateChange(.error)
            }
        }
    }

    // MARK: - Real-Time Transcription Setup

    @available(macOS 13.0, *)
    private func setupRealtimeTranscription(apiKey: String) async -> LiveTranscriptStore {
        let store = await MainActor.run { LiveTranscriptStore() }

        let rtService = realtimeTranscriptionService

        // Stream the exact same mixed mono audio that is written to fallback WAV.
        meetingRecorderService.onRealtimeAudioData = { [weak rtService] pcmData in
            rtService?.sendAudioData(pcmData)
        }

        // Wire token callbacks
        rtService.onTokensReceived = { [weak store] tokens in
            Task { @MainActor in
                store?.processTokens(tokens)
            }
        }

        rtService.onConnectionStatusChanged = { [weak store] status in
            Task { @MainActor in
                store?.connectionStatus = status
            }
        }

        rtService.onError = { error in
            Log.transcription.error("Realtime transcription error: \(error.localizedDescription)")
            // Don't stop recording — file recording continues independently
        }

        // Connect WebSocket (non-blocking — recording works even if this fails)
        do {
            let languageHints = SettingsStorage.shared.sonioxLanguageHints
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            try await rtService.connect(
                apiKey: apiKey,
                languageHints: languageHints,
                strictLanguageHints: SettingsStorage.shared.sonioxLanguageHintsStrict
            )
            await MainActor.run {
                store.isActive = true
            }
            NSLog("[MeetingRT] Real-time transcription connected successfully")
        } catch {
            NSLog("[MeetingRT] Real-time transcription FAILED to connect: %@", error.localizedDescription)
            await MainActor.run {
                store.isActive = true
                store.connectionStatus = .failed(error.localizedDescription)
            }
            // Recording continues — fallback to async transcription on stop
        }

        return store
    }

    // MARK: - Stop Meeting Recording

    func addMeetingChapter() {
        guard appState.meetingRecordingState == .recording,
              let startTime = appState.meetingRecordingStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let chapterNumber = appState.meetingChapters.count + 1
        let chapter = MeetingChapter(timestampSeconds: elapsed, label: "Chapter \(chapterNumber)")
        appState.meetingChapters.append(chapter)
        NotchManager.shared.showInfo(message: "Chapter \(chapterNumber) added", duration: 1.0)
        Log.app.info("Meeting chapter \(chapterNumber) added at \(elapsed)s")
    }

    func stopMeetingRecording() async {
        Log.app.info("stopMeetingRecording: BEGIN")

        guard #available(macOS 13.0, *) else { return }

        // Deactivate chapter bookmark hotkey
        hotkeyService.unregisterChapterHotkey()

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Capture recording start time for duration calculation
        let recordingStartTime = appState.meetingRecordingStartTime

        await MainActor.run {
            appState.meetingRecordingState = .processing
            handleMeetingStateChange(.processing)
        }

        // Finalize and disconnect real-time transcription (if active)
        let hasRealtimeSession = await MainActor.run { appState.liveTranscriptStore != nil }
        if hasRealtimeSession {
            await realtimeTranscriptionService.finalize()
            await realtimeTranscriptionService.disconnect()
            meetingRecorderService.onRealtimeAudioData = nil
        }

        // Mark store as no longer active
        let store = await MainActor.run { appState.liveTranscriptStore }
        await MainActor.run {
            store?.isActive = false
        }

        // Track audioURL for library save in error path
        var capturedAudioURL: URL?
        let stopTime = Date()

        do {
            guard let audioURL = try await meetingRecorderService.stopRecording() else {
                throw MeetingRecorderError.recordingFailed
            }
            capturedAudioURL = audioURL

            Log.app.info("Meeting recording stopped")

            // Check if we have real-time transcript
            let realtimeText = await MainActor.run { store?.finalTranscriptText ?? "" }

            let apiKey = KeychainManager.shared.getSonioxAPIKey()
            let hasApiKey = apiKey != nil && !apiKey!.isEmpty

            let text: String?
            if !realtimeText.isEmpty {
                // Use real-time transcript
                text = realtimeText
                Log.app.info("Using real-time transcript (\(realtimeText.count) chars)")
            } else if hasApiKey {
                // Fallback: upload WAV to async REST API
                Log.app.info("No real-time transcript, falling back to async API...")
                let audioData = try await loadAudioData(from: audioURL)
                Log.app.info("Meeting recording size = \(audioData.count) bytes")

                transcriptionService.apiKey = apiKey!
                text = try await transcriptionService.transcribeMeeting(audioData: audioData)
                Log.app.info("Async meeting transcription received: \(text?.prefix(100) ?? "")...")
            } else {
                // No API key — save audio only, user can transcribe later from Recordings
                text = nil
                Log.app.info("No API key — saving meeting recording without transcription")
            }

            if let text {
                clipboardService.copy(text: text)
                Log.app.info("stopMeetingRecording: Text copied to clipboard")

                if SettingsStorage.shared.autoPaste {
                    Log.app.info("stopMeetingRecording: Auto-pasting")
                    do {
                        try await clipboardService.paste()
                    } catch ClipboardError.accessibilityNotGranted {
                        Log.app.warning("stopMeetingRecording: Accessibility permission needed")
                        PermissionManager.shared.showPermissionAlert(for: .accessibility)
                    } catch {
                        Log.app.error("stopMeetingRecording: Paste failed - \(error.localizedDescription)")
                    }
                }

                // Update state to success
                await MainActor.run {
                    appState.lastTranscription = text
                    appState.meetingRecordingState = .success
                    appState.meetingRecordingStartTime = nil
                    handleMeetingStateChange(.success)
                }
            } else {
                // No transcription — still success (audio was recorded)
                await MainActor.run {
                    appState.lastTranscription = nil
                    appState.meetingRecordingState = .success
                    appState.meetingRecordingStartTime = nil
                    handleMeetingStateChange(.success)
                }
            }
            Log.app.info("stopMeetingRecording: SUCCESS")

            // Save to recordings library (copies file before we delete temp)
            let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
            RecordingsLibraryStorage.shared.saveRecording(
                audioURL: audioURL,
                type: .meeting,
                duration: duration,
                transcriptionText: text
            )

            // Optional operations run after state change (non-blocking for UI)
            if SettingsStorage.shared.playSoundOnCompletion {
                NSSound(named: .init("Funk"))?.play()
            }

            // Clear recovery state on success
            RecoveryStateManager.shared.clearState()

            // Clean up temp file (after library save copied it)
            try? FileManager.default.removeItem(at: audioURL)

        } catch {
            Log.app.error("Meeting transcription failed: \(error)")

            // Save recording without transcription so user can process later
            if let audioURL = capturedAudioURL {
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    audioURL: audioURL,
                    type: .meeting,
                    duration: duration
                )
                // Clean up temp file after library save
                try? FileManager.default.removeItem(at: audioURL)
                RecoveryStateManager.shared.clearState()
            }

            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.meetingRecordingState = .error
                appState.meetingRecordingStartTime = nil
                handleMeetingStateChange(.error)
            }
        }

        // End App Nap prevention
        if let token = meetingActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            meetingActivityToken = nil
        }

        // Keep transcript window open — user closes manually

        Log.app.info("stopMeetingRecording: END")
    }

    // MARK: - Escape Cancel Handler

    private func setupMeetingEscapeCancelHandler() {
        let escapeService = EscapeCancelService.shared

        // On first escape: show confirmation notification
        escapeService.onFirstEscape = { [weak self] in
            NotchManager.shared.showInfo(
                message: "Press ESC again to cancel",
                duration: 1.5
            )

            // Resume showing recording state after info disappears
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.6))
                guard let self,
                      self.appState.meetingRecordingState == .recording else { return }
                NotchManager.shared.startRecording(mode: .meeting)
            }
        }

        // On second escape (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] in
            guard #available(macOS 13.0, *) else { return }
            Task { @MainActor in
                await self?.cancelMeetingRecording()
                NotchManager.shared.showInfo(message: "Recording cancelled")
            }
        }

        escapeService.activate()
    }

}
