import AppKit
import Combine
import Foundation

actor RealtimeTranslationAccumulator {
    private var finalOriginalText: String = ""
    private var finalTranslatedText: String = ""
    private var provisionalOriginalText: String = ""
    private var provisionalTranslatedText: String = ""

    func process(tokens: [RealtimeToken]) {
        var latestProvisionalOriginalText = ""
        var latestProvisionalTranslatedText = ""
        var didReceiveFinalOriginalToken = false
        var didReceiveFinalTranslatedToken = false

        for token in tokens where !token.text.isEmpty {
            let status = token.translationStatus?.lowercased()
            switch status {
            case "translation":
                if token.isFinal {
                    finalTranslatedText += token.text
                    didReceiveFinalTranslatedToken = true
                } else {
                    latestProvisionalTranslatedText += token.text
                }
            case "transcription", "source", "original", "none", nil:
                if token.isFinal {
                    finalOriginalText += token.text
                    didReceiveFinalOriginalToken = true
                } else {
                    latestProvisionalOriginalText += token.text
                }
            default:
                if token.isFinal {
                    finalOriginalText += token.text
                    didReceiveFinalOriginalToken = true
                } else {
                    latestProvisionalOriginalText += token.text
                }
            }
        }

        if !latestProvisionalTranslatedText.isEmpty {
            provisionalTranslatedText = latestProvisionalTranslatedText
        } else if didReceiveFinalTranslatedToken {
            provisionalTranslatedText = ""
        }

        if !latestProvisionalOriginalText.isEmpty {
            provisionalOriginalText = latestProvisionalOriginalText
        } else if didReceiveFinalOriginalToken {
            provisionalOriginalText = ""
        }
    }

    func markSegmentBoundary() {
        // No-op: pause-based formatting removed
    }

    func bestText(includeProvisional: Bool = true) -> String {
        let translatedText = includeProvisional
            ? finalTranslatedText + provisionalTranslatedText
            : finalTranslatedText
        let translated = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !translated.isEmpty {
            return translated
        }

        let originalText = includeProvisional
            ? finalOriginalText + provisionalOriginalText
            : finalOriginalText
        return originalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Translation Recording

extension AppDelegate {
    @objc func toggleTranslationRecording() {
        let translationRecordingState = appState.translationRecordingState
        Log.app.info("toggleTranslationRecording called, current state: \(translationRecordingState)")

        translationPipelineTask?.cancel()
        translationPipelineTask = Task {
            await self.performToggleTranslationRecording()
        }
    }

    func performToggleTranslationRecording() async {
        let translationRecordingState = appState.translationRecordingState
        switch translationRecordingState {
        case .idle:
            await startTranslationRecording()
        case .recording:
            await stopTranslationRecording()
        case .processing:
            Log.app.info("Translation state is processing, canceling...")
            await cancelTranslationRecording(cancelTask: false)
        default:
            Log.app.info("Translation state is \(translationRecordingState), ignoring toggle")
        }
    }

    func cancelTranslationRecording(cancelTask: Bool = true) async {
        Log.app.info("cancelTranslationRecording: BEGIN")

        // Cancel any in-flight pipeline task (skip when called from within the task itself)
        if cancelTask {
            translationPipelineTask?.cancel()
        }
        translationPipelineTask = nil

        let recordingStartTime = appState.translationRecordingStartTime
        let stopTime = Date()
        let targetLanguage = activeTranslationTargetLanguage
            ?? activeTranslationLanguagePair?.languageB
            ?? SettingsStorage.shared.voiceTranslationTargetLanguage

        // Stop audio level piping
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        // Stop realtime translation session (if active)
        _ = await stopTranslationRealtimeSession(finalize: false)

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        if SettingsStorage.shared.escapeCancelSaveAudio, audioRecorder.isRecording {
            do {
                let sourceDevice = audioRecorder.currentRecordingDeviceInfo
                let audioData = try await audioRecorder.stopRecording()
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    audioData: audioData,
                    type: .translation,
                    duration: duration,
                    sourceDevice: sourceDevice,
                    translationTargetLanguageCode: targetLanguage
                )
                Log.app.info("cancelTranslationRecording: audio saved after cancel")
            } catch {
                Log.app
                    .warning(
                        "cancelTranslationRecording: failed to save audio on cancel - \(error.localizedDescription)"
                    )
                audioRecorder.cancelRecording()
            }
        } else {
            // Cancel audio recorder without persisting
            audioRecorder.cancelRecording()
        }

        // End App Nap prevention
        if let token = translationActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            translationActivityToken = nil
        }

        // Clear recovery state
        RecoveryStateManager.shared.clearState()

        // Reset push-to-talk hands-free mode if active
        translationPushToTalkService.resetHandsFreeMode()

        // Reset state to idle
        await MainActor.run {
            appState.translationRecordingState = .idle
            appState.translationRecordingStartTime = nil
            handleTranslationStateChange(.idle)
            activeTranslationLanguagePair = nil
            activeTranslationTargetLanguage = nil
        }

        Log.app.info("cancelTranslationRecording: END")
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

    func startTranslationRecording(languagePair requestedPair: TranslationLanguagePair? = nil) async {
        Log.app.info("startTranslationRecording: BEGIN")

        guard canStartRecording(kind: .translation) else {
            Log.app.info("startTranslationRecording: blocked by another active recording mode")
            return
        }

        let pair = requestedPair ?? SettingsStorage.shared.resolveTranslationLanguagePair()
        SettingsStorage.shared.markTranslationLanguagePairUsed(pair)
        let targetLanguage = pair.languageB
        activeTranslationLanguagePair = pair
        activeTranslationTargetLanguage = targetLanguage
        SettingsStorage.shared.voiceTranslationTargetLanguage = targetLanguage

        // Request microphone permission on-demand
        let micGranted = await PermissionManager.shared.ensureMicrophonePermission(context: .translation)
        appState.microphonePermissionGranted = micGranted

        guard micGranted else {
            Log.app.warning("startTranslationRecording: Microphone permission not granted")
            await MainActor.run {
                appState.errorMessage = "Microphone access required"
                appState.translationRecordingState = .error
                handleTranslationStateChange(.error)
                activeTranslationLanguagePair = nil
                activeTranslationTargetLanguage = nil
            }
            return
        }

        if SettingsStorage.shared.effectiveTranslationProvider == .local, !pair.contains("en") {
            Log.app.warning("startTranslationRecording: Local Whisper can translate only to English")
            await MainActor.run {
                appState.errorMessage = "Local Whisper can translate to English only. Switch Translation Provider to Cloud or choose English."
                appState.translationRecordingState = .error
                handleTranslationStateChange(.error)
                activeTranslationLanguagePair = nil
                activeTranslationTargetLanguage = nil
            }
            return
        }

        // Provider-specific validation for Local mode
        if SettingsStorage.shared.effectiveTranslationProvider == .local {
            guard let model = WhisperModelManager.shared.selectedModel() else {
                Log.app.warning("startTranslationRecording: No Whisper model selected")
                await MainActor.run {
                    appState.errorMessage = "No Whisper model downloaded. Please download one in Settings."
                    appState.translationRecordingState = .error
                    handleTranslationStateChange(.error)
                    activeTranslationLanguagePair = nil
                    activeTranslationTargetLanguage = nil
                }
                return
            }
            if model.isEnglishOnly {
                Log.app.warning("startTranslationRecording: English-only model cannot translate")
                await MainActor.run {
                    appState.errorMessage = WhisperError.modelDoesNotSupportTranslation.localizedDescription
                    appState.translationRecordingState = .error
                    handleTranslationStateChange(.error)
                    activeTranslationLanguagePair = nil
                    activeTranslationTargetLanguage = nil
                }
                return
            }
        }
        Log.app.info("startTranslationRecording: Provider ready, pair=\(pair.displayLabel)")
        translationRealtimeSessionEnabled = false

        // Resolve device (nil preference = System Default)
        let (device, didFallback) = audioDeviceManager.resolveDevice(
            preferredUID: appState.preferredDeviceUID
        )
        if didFallback, let name = device?.name {
            Log.app.warning("startTranslationRecording: Preferred device unavailable, using \(name)")
        }
        guard let device else {
            Log.app.error("startTranslationRecording: No audio input devices available")
            await MainActor.run {
                appState.errorMessage = "No microphone found. Please connect a microphone."
                appState.translationRecordingState = .error
                handleTranslationStateChange(.error)
                activeTranslationLanguagePair = nil
                activeTranslationTargetLanguage = nil
            }
            return
        }

        Log.app.info("startTranslationRecording: Setting state to processing")

        // Prevent App Nap during translation recording
        translationActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Translation recording in progress"
        )

        // Show processing state while initializing audio (before we confirm it works)
        await MainActor.run {
            appState.translationRecordingState = .processing
            handleTranslationStateChange(.processing)
        }

        do {
            // Set up realtime callback BEFORE starting recorder (AudioRecorderService
            // snapshots onRealtimeAudioData at start time). WebSocket connects in background.
            setupRealtimeTranslationIfNeeded()

            Log.app.info("startTranslationRecording: Starting audio recording")
            _ = try await startAudioRecorderWithFallback(
                initialDevice: device,
                logPrefix: "startTranslationRecording"
            )
            Log.app.info("startTranslationRecording: Recording started successfully")

            // Only set recording state AFTER audio engine is confirmed working
            let recordingStateAfterStart = appState.translationRecordingState
            guard recordingStateAfterStart == .processing else {
                Log.app
                    .warning(
                        "startTranslationRecording: state changed during init (now \(recordingStateAfterStart)), aborting"
                    )
                audioRecorder.cancelRecording()
                _ = await stopTranslationRealtimeSession(finalize: false)
                if let token = translationActivityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    translationActivityToken = nil
                }
                activeTranslationLanguagePair = nil
                activeTranslationTargetLanguage = nil
                return
            }
            await MainActor.run {
                appState.translationRecordingState = .recording
                appState.translationRecordingStartTime = Date()
                handleTranslationStateChange(.recording)

                // Pipe audio level to the selected recording feedback surface.
                let feedbackMode: RecordingMode = .translation(targetLanguage: translationPairLabel)
                audioLevelCancellable = audioRecorder.$audioLevel
                    .removeDuplicates()
                    .sink { [weak self] level in
                        self?.updateRecordingFeedbackAudioLevel(level, mode: feedbackMode)
                    }
            }

            wireDeviceLostNotification()

            // Activate escape cancel handler
            await MainActor.run {
                setupTranslationEscapeCancelHandler()
            }
        } catch let error as AudioTimeoutError {
            // Audio hardware timed out - likely coreaudiod is unresponsive or device is unavailable
            Log.app.error("startTranslationRecording: TIMEOUT - \(error.localizedDescription)")

            _ = await stopTranslationRealtimeSession(finalize: false)

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
                activeTranslationLanguagePair = nil
                activeTranslationTargetLanguage = nil
            }

            return
        } catch {
            // Handle any other errors during recording start
            Log.app.error("startTranslationRecording: ERROR - \(error.localizedDescription)")

            _ = await stopTranslationRealtimeSession(finalize: false)

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
                activeTranslationLanguagePair = nil
                activeTranslationTargetLanguage = nil
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

        // Stop audio level piping
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Capture recording start time for duration calculation
        let recordingStartTime = appState.translationRecordingStartTime
        let pair = activeTranslationLanguagePair ?? SettingsStorage.shared.resolveTranslationLanguagePair()
        let targetLanguage = activeTranslationTargetLanguage ?? pair.languageB

        // Capture stop time immediately for accurate duration
        let stopTime = Date()

        await MainActor.run {
            appState.translationRecordingState = .processing
            handleTranslationStateChange(.processing)
        }

        // Capture audio data first so it's available in both success and error paths
        var capturedAudioData: Data?
        let recordingId = UUID()
        let sourceDevice = audioRecorder.currentRecordingDeviceInfo
        let realtimeStopTask = Task { @MainActor in
            await self.stopTranslationRealtimeSession(finalize: true)
        }

        do {
            Log.app.info("stopTranslationRecording: Stopping audio recorder")
            let audioData = try await audioRecorder.stopRecording()
            Log.app.info("stopTranslationRecording: Got audio data, size = \(audioData.count) bytes")

            capturedAudioData = audioData

            let realtimeResult = await realtimeStopTask.value

            let rawText: String
            if !realtimeResult.text.isEmpty {
                rawText = realtimeResult.text
                Log.app.info("stopTranslationRecording: Using realtime translation (\(rawText.count) chars)")
            } else if SettingsStorage.shared.effectiveTranslationProvider == .local {
                // Local Whisper — no WebSocket, transcribe from audio
                rawText = try await whisperTranscriptionService.translateAndTranscribe(
                    audioData: audioData,
                    languagePair: pair
                )
                Log.app.info("stopTranslationRecording: Local Whisper translation (\(rawText.count) chars)")
            } else {
                rawText = try await transcriptionService.translateAndTranscribe(
                    audioData: audioData,
                    languagePair: pair
                )
                Log.app.info("stopTranslationRecording: HTTP cloud translation (\(rawText.count) chars)")
            }
            let cleanedRawText: String
            if !realtimeResult.text.isEmpty {
                cleanedRawText = await cleanRealtimeResultText(
                    rawText,
                    realtimeResult: realtimeResult,
                    logPrefix: "Translation"
                )
            } else {
                cleanedRawText = await TranscriptCleanupService.shared.clean(
                    rawText,
                    fillerWords: SettingsStorage.shared.fillerWords
                )
            }
            let text = ClipboardService.preparedText(cleanedRawText, behavior: .cleaned)
            Log.app.info("stopTranslationRecording: Translation received (\(text.count) chars)")

            let processingState = appState.translationRecordingState
            guard processingState == .processing else {
                Log.app
                    .warning(
                        "stopTranslationRecording: state changed during processing (now \(processingState)), dropping result"
                    )
                return
            }

            clipboardService.copy(text: text, behavior: .raw)
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

            await MainActor.run {
                appState.lastTranscription = text
                appState.isEmptyTranscription = false
                appState.translationRecordingState = .success
                appState.translationRecordingStartTime = nil
                handleTranslationStateChange(.success)
                activeTranslationLanguagePair = nil
                activeTranslationTargetLanguage = nil
            }
            Log.app.info("stopTranslationRecording: SUCCESS")

            let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
            let compressedData = await AudioCompressionService.compressToFLAC(audioData: audioData)
            capturedAudioData = compressedData
            RecordingsLibraryStorage.shared.saveRecording(
                id: recordingId,
                audioData: compressedData,
                type: .translation,
                duration: duration,
                transcriptionText: text,
                sourceDevice: sourceDevice,
                translationTargetLanguageCode: targetLanguage
            )

            if SettingsStorage.shared.playSoundOnCompletion {
                Log.app.info("stopTranslationRecording: Playing sound")
                NSSound(named: .init("Funk"))?.play()
            }

            RecoveryStateManager.shared.clearState()

        } catch is CancellationError {
            _ = await realtimeStopTask.value
            Log.app.info("stopTranslationRecording: Cancelled")
            await MainActor.run {
                appState.translationRecordingState = .idle
                appState.translationRecordingStartTime = nil
                handleTranslationStateChange(.idle)
                activeTranslationLanguagePair = nil
                activeTranslationTargetLanguage = nil
            }
            return
        } catch {
            _ = await realtimeStopTask.value
            Log.app.error("stopTranslationRecording: ERROR - \(error.localizedDescription)")
            let isEmptyTranscription: Bool = {
                guard case .emptyTranscription = error as? TranscriptionError else { return false }
                return true
            }()

            if let audioData = capturedAudioData {
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    id: recordingId,
                    audioData: audioData,
                    type: .translation,
                    duration: duration,
                    sourceDevice: sourceDevice,
                    translationTargetLanguageCode: targetLanguage
                )
                RecoveryStateManager.shared.clearState()
            }

            let processingState = appState.translationRecordingState
            guard processingState == .processing else {
                Log.app
                    .warning(
                        "stopTranslationRecording: state changed during processing (now \(processingState)), dropping error"
                    )
                return
            }
            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.isEmptyTranscription = isEmptyTranscription
                appState.translationRecordingState = .error
                appState.translationRecordingStartTime = nil
                handleTranslationStateChange(.error)
                activeTranslationLanguagePair = nil
                activeTranslationTargetLanguage = nil
            }
        }

        // End App Nap prevention
        if let token = translationActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            translationActivityToken = nil
        }

        Log.app.info("stopTranslationRecording: END")
    }

    // MARK: - Realtime Translation (WebSocket)

    private func setupRealtimeTranslationIfNeeded() {
        guard SettingsStorage.shared.effectiveTranslationProvider == .cloud else {
            audioRecorder.onRealtimeAudioData = nil
            translationRealtimeSessionEnabled = false
            translationRealtimeAccumulator = nil
            return
        }

        let pair = activeTranslationLanguagePair ?? SettingsStorage.shared.resolveTranslationLanguagePair()
        let feedbackMode: RecordingMode = .translation(targetLanguage: translationPairLabel)
        let accumulator = RealtimeTranslationAccumulator()
        translationRealtimeAccumulator = accumulator

        let rtService = realtimeTranscriptionService
        audioRecorder.onRealtimeAudioData = { [weak rtService] pcmData in
            rtService?.sendAudioData(pcmData)
        }

        rtService.onTokensReceived = { [weak self, weak accumulator] tokens in
            if let accumulator {
                Task {
                    await accumulator.process(tokens: tokens)
                }
            }
            Task { @MainActor in
                self?.updateRecordingFeedbackTokens(tokens, mode: feedbackMode)
            }
        }

        rtService.onConnectionStatusChanged = { [weak self] status in
            Log.transcription.info("Translation RT status: \(String(describing: status))")
            Task { @MainActor in
                self?.updateRecordingFeedbackConnectionStatus(status, mode: feedbackMode)
            }
        }

        rtService.onSegmentBoundary = { [weak accumulator] _ in
            guard let accumulator else { return }
            Task {
                await accumulator.markSegmentBoundary()
            }
        }

        rtService.onError = { [weak self] error in
            Log.transcription.error("Translation RT error: \(error.localizedDescription)")
            Task { @MainActor in
                self?.updateRecordingFeedbackConnectionStatus(.failed(error.localizedDescription), mode: feedbackMode)
            }
        }

        translationRealtimeConnectionError = nil

        // Connect WebSocket in background — don't block recording start
        translationRealtimeConnectionTask = Task {
            do {
                let languageHints = SettingsStorage.shared.translationLanguageHints(for: pair)
                try await rtService.connect(
                    languageHints: languageHints,
                    strictLanguageHints: !languageHints.isEmpty,
                    audioConfig: .defaultPCM16kMono,
                    translationConfig: RealtimeTranslationConfig(
                        mode: .twoWay(languageA: pair.languageA, languageB: pair.languageB)
                    ),
                    enableSpeakerDiarization: false
                )

                await MainActor.run {
                    self.translationRealtimeSessionEnabled = true
                    self.updateRecordingFeedbackConnectionStatus(.connected, mode: feedbackMode)
                }
                NSLog("[Transcription] Translation RT connected (%@ <-> %@)", pair.languageA, pair.languageB)
            } catch {
                await MainActor.run {
                    self.audioRecorder.onRealtimeAudioData = nil
                    self.translationRealtimeSessionEnabled = false
                    self.translationRealtimeAccumulator = nil
                    self.translationRealtimeConnectionError = error.localizedDescription
                    self.updateRecordingFeedbackConnectionStatus(.failed(error.localizedDescription), mode: feedbackMode)
                }
                NSLog("[Transcription] Translation RT connection failed: %@", error.localizedDescription)
            }
        }
    }

    private func stopTranslationRealtimeSession(finalize: Bool) async -> RealtimeSessionStopResult {
        translationRealtimeConnectionTask?.cancel()
        translationRealtimeConnectionTask = nil
        if !finalize {
            audioRecorder.onRealtimeAudioData = nil
        }

        let accumulator = translationRealtimeAccumulator
        let wasEnabled = translationRealtimeSessionEnabled

        defer {
            audioRecorder.onRealtimeAudioData = nil
            translationRealtimeSessionEnabled = false
            translationRealtimeAccumulator = nil
            realtimeTranscriptionService.onTokensReceived = nil
            realtimeTranscriptionService.onError = nil
            realtimeTranscriptionService.onConnectionStatusChanged = nil
            realtimeTranscriptionService.onSegmentBoundary = nil
        }

        guard wasEnabled else {
            return .empty
        }

        let preFinalizeText: String
        if finalize {
            preFinalizeText = await accumulator?.bestText(includeProvisional: true) ?? ""
        } else {
            preFinalizeText = ""
        }
        let optimisticCleanupTask = finalize
            ? startOptimisticRealtimeCleanup(for: preFinalizeText)
            : nil
        var finalizeResult: RealtimeFinalizeResult = .skipped
        if finalize {
            finalizeResult = await realtimeTranscriptionService.finalize(profile: .dictationFast)
        }
        await realtimeTranscriptionService.disconnect()

        let text = (await accumulator?.bestText(includeProvisional: true) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preFinalizeTrimmed = preFinalizeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let textChangedAfterFinalize = text != preFinalizeTrimmed
        let optimisticCleanedText: String?

        if let optimisticCleanupTask, !textChangedAfterFinalize {
            optimisticCleanedText = await optimisticCleanupTask.value
        } else {
            optimisticCleanupTask?.cancel()
            optimisticCleanedText = nil
        }

        Log.transcription.info(
            "Translation RT stop: finalizeProfile=\(finalizeResult.profileName), finished=\(finalizeResult.didReceiveFinishedSignal), timedOut=\(finalizeResult.timedOut), durationMs=\(finalizeResult.durationMs), tokensAfterFinalize=\(finalizeResult.tokensAfterFinalize), charsAfterFinalize=\(finalizeResult.charactersAfterFinalize), textChangedAfterFinalize=\(textChangedAfterFinalize), charsDelta=\(text.count - preFinalizeTrimmed.count), optimisticCleanupReused=\(optimisticCleanedText != nil)"
        )

        return RealtimeSessionStopResult(
            text: text,
            preFinalizeText: preFinalizeTrimmed,
            optimisticCleanedText: optimisticCleanedText,
            finalizeResult: finalizeResult
        )
    }

    // MARK: - Escape Cancel Handler

    private func setupTranslationEscapeCancelHandler() {
        let escapeService = EscapeCancelService.shared
        guard SettingsStorage.shared.escapeCancelEnabled else {
            escapeService.deactivate()
            return
        }

        escapeService.onProgressEscape = { [weak self] pressCount, _ in
            guard let self else { return }
            self.showRecordingInfoDuringActiveRecording(
                message: SettingsStorage.shared.escapeCancelRepeatHint(afterPressCount: pressCount),
                mode: .translation(targetLanguage: translationPairLabel),
                duration: 1.5
            )
        }

        // On second shortcut press (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let shouldSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio
                await self.cancelTranslationRecording()
                let message = shouldSaveAudio ? "Recording cancelled and saved" : "Recording cancelled"
                self.showRecordingFeedbackInfo(
                    message: message,
                    mode: .translation(targetLanguage: self.translationPairLabel)
                )
            }
        }

        escapeService.activate()
    }
}
