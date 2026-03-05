import AppKit
import Foundation

// MARK: - Meeting Recording

extension AppDelegate {
    @objc func toggleMeetingRecording() {
        Log.app.info("toggleMeetingRecording called, current state: \(self.appState.meetingRecordingState)")
        meetingPipelineTask?.cancel()
        meetingPipelineTask = Task {
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

        // Cancel any in-flight pipeline task
        meetingPipelineTask?.cancel()
        meetingPipelineTask = nil

        let recordingStartTime = appState.meetingRecordingStartTime
        let stopTime = Date()

        // Deactivate chapter bookmark hotkey
        hotkeyService.unregisterChapterHotkey()

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Disconnect real-time transcription (if active)
        if appState.liveTranscriptStore != nil {
            await realtimeTranscriptionService.disconnect()
            meetingRecorderService.onRealtimeAudioData = nil
        }

        if SettingsStorage.shared.escapeCancelSaveAudio, meetingRecorderService.isRecording {
            do {
                if let audioURL = try await meetingRecorderService.stopRecording() {
                    let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                    RecordingsLibraryStorage.shared.saveRecording(
                        audioURL: audioURL,
                        type: .meeting,
                        duration: duration
                    )
                    try? FileManager.default.removeItem(at: audioURL)
                    Log.app.info("cancelMeetingRecording: audio saved after cancel")
                } else {
                    await meetingRecorderService.cancelRecording()
                }
            } catch {
                Log.app.warning("cancelMeetingRecording: failed to save audio on cancel - \(error.localizedDescription)")
                await meetingRecorderService.cancelRecording()
            }
        } else {
            // Cancel meeting recorder without persisting
            await meetingRecorderService.cancelRecording()
        }

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

        // API key is optional — recording always works, cloud mode requires key
        let apiKey = KeychainManager.shared.getSonioxAPIKey()
        let hasApiKey = apiKey?.isEmpty == false
        let cloudModeEnabled = SettingsStorage.shared.meetingRealtimeTranscriptionEnabled

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
            if let selectedUID = appState.selectedDeviceUID {
                meetingRecorderService.microphoneDevice = audioDeviceManager.device(forUID: selectedUID)
                    ?? audioDeviceManager.bestDevice()
                    ?? audioDeviceManager.getCurrentDefaultDevice()
            } else {
                meetingRecorderService.microphoneDevice = audioDeviceManager.bestDevice()
                    ?? audioDeviceManager.getCurrentDefaultDevice()
            }

            try await meetingRecorderService.startRecording()
            Log.app.info("Meeting recording started")

            // Setup real-time transcription only in Cloud mode with API key
            var store: LiveTranscriptStore?
            if hasApiKey, cloudModeEnabled, let key = apiKey {
                store = await setupRealtimeTranscription(apiKey: key)
            } else if cloudModeEnabled {
                Log.app.info("Cloud mode selected, but API key missing — recording audio only")
            } else {
                Log.app.info("Local mode selected — recording audio only")
            }

            // Only set recording state AFTER confirmed working
            guard appState.meetingRecordingState == .processing else {
                Log.app.warning("startMeetingRecording: state changed during init (now \(self.appState.meetingRecordingState)), aborting")
                await meetingRecorderService.cancelRecording()
                if let token = meetingActivityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    meetingActivityToken = nil
                }
                return
            }
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

        rtService.onSegmentBoundary = { [weak store] _ in
            Task { @MainActor in
                store?.markSegmentBoundary()
            }
        }

        rtService.onError = { error in
            Log.transcription.error("Realtime transcription error: \(error.localizedDescription)")
            // Don't stop recording — file recording continues independently
        }

        // Connect WebSocket (non-blocking — recording works even if this fails)
        do {
            let languageHints = SettingsStorage.shared.favoriteLanguages

            try await rtService.connect(
                apiKey: apiKey,
                languageHints: languageHints,
                strictLanguageHints: !languageHints.isEmpty,
                enableEndpointDetection: true,
                maxEndpointDelayMs: SettingsStorage.shared.sonioxEndpointDelayMs
            )
            await MainActor.run {
                store.isActive = true
            }
            Log.transcription.info("Meeting real-time transcription connected successfully")
        } catch {
            Log.transcription.error("Meeting real-time transcription FAILED to connect: \(error.localizedDescription)")
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
            _ = await realtimeTranscriptionService.finalize()
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
        let recordingId = UUID()

        await RecordingDebugScope.$recordingID.withValue(recordingId) {
            RecordingDebugLog.app("Meeting stop pipeline started", source: "Meeting")
            do {
                guard let audioURL = try await meetingRecorderService.stopRecording() else {
                    throw MeetingRecorderError.recordingFailed
                }
                capturedAudioURL = audioURL

                Log.app.info("Meeting recording stopped")

                // Check if we have real-time transcript
                let realtimeText = await MainActor.run { store?.finalTranscriptText ?? "" }

                let apiKey = KeychainManager.shared.getSonioxAPIKey()
                let hasApiKey = apiKey?.isEmpty == false
                let cloudModeEnabled = SettingsStorage.shared.meetingRealtimeTranscriptionEnabled
                RecordingDebugLog.decision(
                    "Realtime chars=\(realtimeText.count), cloudMode=\(cloudModeEnabled), hasApiKey=\(hasApiKey)",
                    source: "Meeting"
                )

                let text: String?
                if !realtimeText.isEmpty {
                    // Use real-time transcript
                    text = realtimeText
                    Log.app.info("Using real-time transcript (\(realtimeText.count) chars)")
                    RecordingDebugLog.decision("Using realtime transcript", source: "Meeting")
                } else if hasApiKey, cloudModeEnabled {
                    // Fallback: upload WAV to async REST API
                    Log.app.info("No real-time transcript, falling back to async API...")
                    RecordingDebugLog.decision("Fallback to async Soniox meeting transcription", source: "Meeting")
                    let audioData = try await loadAudioData(from: audioURL)
                    Log.app.info("Meeting recording size = \(audioData.count) bytes")

                    transcriptionService.apiKey = apiKey
                    text = try await transcriptionService.transcribeMeeting(audioData: audioData)
                    Log.app.info("Async meeting transcription received: \(text?.prefix(100) ?? "")...")
                } else {
                    // Local mode or missing API key — save audio only, user can transcribe later from Recordings
                    text = nil
                    Log.app.info("Saving meeting recording without automatic transcription")
                    RecordingDebugLog.decision("No transcription path (local mode or missing API key)", source: "Meeting")
                }

                guard appState.meetingRecordingState == .processing else {
                    Log.app.warning("stopMeetingRecording: state changed during processing (now \(self.appState.meetingRecordingState)), dropping result")
                    return
                }

                if let text {
                    clipboardService.copy(text: text, behavior: .raw)
                    Log.app.info("stopMeetingRecording: Text copied to clipboard")
                    RecordingDebugLog.app("Text ready, chars=\(text.count)", source: "Meeting")

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

                    if !cloudModeEnabled {
                        NotchManager.shared.showInfo(
                            message: "Recording saved. Open Recordings and choose a local model to transcribe.",
                            duration: 3.0
                        )
                    }
                }
                Log.app.info("stopMeetingRecording: SUCCESS")

                // Save to recordings library (copies file before we delete temp)
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    id: recordingId,
                    audioURL: audioURL,
                    type: .meeting,
                    duration: duration,
                    transcriptionText: text
                )
                RecordingDebugLog.app("Recording saved to library", source: "Meeting")

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
                RecordingDebugLog.app("Stop pipeline failed: \(error.localizedDescription)", source: "Meeting")

                // Save recording without transcription so user can process later
                if let audioURL = capturedAudioURL {
                    let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                    RecordingsLibraryStorage.shared.saveRecording(
                        id: recordingId,
                        audioURL: audioURL,
                        type: .meeting,
                        duration: duration
                    )
                    // Clean up temp file after library save
                    try? FileManager.default.removeItem(at: audioURL)
                    RecoveryStateManager.shared.clearState()
                    RecordingDebugLog.app("Saved audio-only after failure", source: "Meeting")
                }

                guard appState.meetingRecordingState == .processing else {
                    Log.app.warning("stopMeetingRecording: state changed during processing (now \(self.appState.meetingRecordingState)), dropping error")
                    return
                }
                await MainActor.run {
                    appState.errorMessage = error.localizedDescription
                    appState.meetingRecordingState = .error
                    appState.meetingRecordingStartTime = nil
                    handleMeetingStateChange(.error)
                }
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
        guard SettingsStorage.shared.escapeCancelEnabled else {
            escapeService.deactivate()
            return
        }

        // On first shortcut press: show confirmation notification
        escapeService.onFirstEscape = { [weak self] in
            NotchManager.shared.showInfo(
                message: SettingsStorage.shared.escapeCancelShortcut.repeatHint,
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

        // On second shortcut press (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] in
            guard #available(macOS 13.0, *) else { return }
            Task { @MainActor in
                let shouldSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio
                await self?.cancelMeetingRecording()
                let message = shouldSaveAudio ? "Recording cancelled and saved" : "Recording cancelled"
                NotchManager.shared.showInfo(message: message)
            }
        }

        escapeService.activate()
    }

}
