import AppKit
import Foundation

// MARK: - Meeting Recording

extension AppDelegate {
    /// Hotkey, menu and tile start: "Starts in" and its engine from Settings > Modes (WP-17, T1-MT-14).
    @objc func toggleMeetingRecording() {
        guard appState.meetingRecordingState == .idle else {
            return toggleMeetingRecording(provider: activeMeetingTranscriptionProvider ?? .local)
        }
        startMeeting(meetingStartRoute())
    }

    /// Start from the meeting prompt (WP-43): the prompt's segment decides where audio goes.
    /// Record only never streams live; it records on this Mac and transcribes after Stop.
    func startMeetingRecording(from start: MeetingPromptStart) {
        guard appState.meetingRecordingState == .idle else { return }
        startMeeting(meetingStartRoute(segment: start.segment))
    }

    /// Starts in `route`'s segment with its engine; refuses an on-device engine that is not ready.
    func startMeeting(_ route: MeetingStartRoute, calendarMeeting: CalendarMeeting? = nil) {
        if let message = onDeviceEngineStartError(for: route) {
            DictationOverlayController.shared.showInfo(message: message, duration: 4)
            return
        }
        toggleMeetingRecording(provider: route.provider, calendarMeeting: calendarMeeting,
                               recordOnly: route.recordOnly, startRoute: route)
    }

    func toggleMeetingRecording(
        provider: TranscriptionProvider,
        calendarMeeting: CalendarMeeting? = nil,
        translateTarget: String? = nil,
        recordOnly: Bool = false,
        startRoute: MeetingStartRoute? = nil,
        cancelPipeline: (() async -> Void)? = nil
    ) {
        let meetingRecordingState = appState.meetingRecordingState
        Log.app.info("toggleMeetingRecording called, current state: \(meetingRecordingState)")

        // Task ownership: the stop pipeline runs inside meetingPipelineTask,
        // so a blanket cancel here would kill an in-flight stop (transcription
        // upload included) and silently drop the meeting. Only the explicit
        // cancel-while-processing branch may cancel it — from outside the
        // task being cancelled.
        switch meetingRecordingState {
        case .idle:
            guard canStartRecording(kind: .meeting) else { return }
            meetingPipelineGeneration &+= 1
            ShareableContentCache.shared.prewarm()
            if provider == .cloud {
                Task { _ = await AuthService.shared.getAccessToken() }
            }
            meetingPipelineTask?.cancel()
            appState.meetingRecordingState = .processing
            handleMeetingStateChange(.processing)
            let generation = meetingPipelineGeneration
            meetingPipelineTask = Task {
                await self.startMeetingRecording(provider: provider, calendarMeeting: calendarMeeting,
                                                 translateTarget: translateTarget,
                                                 recordOnly: recordOnly,
                                                 startRoute: startRoute,
                                                 pipelineGeneration: generation)
            }
        case .recording:
            meetingPipelineTask = Task {
                await self.stopMeetingRecording()
            }
        case .processing:
            Log.app.info("Meeting state is processing, canceling...")
            cancelMeetingPipeline(cancelPipeline: cancelPipeline)
        default:
            Log.app.info("Meeting state is \(meetingRecordingState), ignoring toggle")
        }
    }

    @discardableResult
    func cancelMeetingPipeline(
        cancelPipeline: (() async -> Void)? = nil
    ) -> Task<Void, Never>? {
        let state = appState.meetingRecordingState
        guard state == .processing || state == .recording else { return nil }

        let cancellationGeneration = meetingPipelineGeneration
        let inFlightTask = meetingPipelineTask
        inFlightTask?.cancel()
        let cancellationTask = Task {
            if let inFlightTask {
                await inFlightTask.value
            }
            let currentState = self.appState.meetingRecordingState
            guard !Task.isCancelled,
                  currentState == .processing || currentState == .recording,
                  self.meetingPipelineGeneration == cancellationGeneration
            else { return }
            if let cancelPipeline {
                await cancelPipeline()
            } else {
                await self.cancelMeetingRecording()
            }
        }
        meetingPipelineTask = cancellationTask
        return cancellationTask
    }

    /// Tears down an active or processing meeting recording. Callers that need
    /// to abort an in-flight pipeline task must cancel it themselves before
    /// calling — this method must never cancel the task it may be running in
    /// (self-cancel made the save-audio-on-cancel branch fail silently).
    func cancelMeetingRecording() async {
        Log.app.info("cancelMeetingRecording: BEGIN")
        defer {
            activeMeetingTranscriptionSessionID = nil
            activeMeetingTranscriptionProvider = nil
            activeMeetingStartRoute = nil
            activeMeetingTranslateTarget = nil
        }

        let recordingStartTime = appState.meetingRecordingStartTime
        let stopTime = Date()

        // Deactivate chapter bookmark hotkey
        hotkeyService.unregisterChapterHotkey()

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Disconnect real-time transcription (if active or still connecting).
        _ = await stopMeetingLiveTranscription()

        // Capture in-progress recording ID before stopRecording() clears it (RLR-M1).
        let cancelInProgressRecordingId = meetingRecorderService.currentRecordingId

        if SettingsStorage.shared.escapeCancelSaveAudio, meetingRecorderService.isRecording {
            do {
                if let audioURL = try await meetingRecorderService.stopRecording() {
                    let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                    var saved = false
                    if let ipId = cancelInProgressRecordingId,
                       RecordingsLibraryStorage.shared.recordings.contains(where: { $0.id == ipId })
                    {
                        saved = RecordingsLibraryStorage.shared.finalizeInProgressRecording(
                            id: ipId,
                            audioURL: audioURL,
                            duration: duration,
                            endedAt: stopTime,
                            status: .unprocessed,
                            forceSave: true
                        )
                    } else {
                        saved = RecordingsLibraryStorage.shared.saveRecording(
                            id: cancelInProgressRecordingId,
                            audioURL: audioURL,
                            type: .meeting,
                            duration: duration,
                            createdAt: recordingStartTime ?? stopTime,
                            forceSave: true
                        ) != nil
                    }
                    // Only clean up after durable library handoff.
                    if saved, let ipId = cancelInProgressRecordingId {
                        if let store = try? InProgressRecordingStore.sharedStore() {
                            try? await store.cleanup(recordingId: ipId)
                        }
                        try? FileManager.default.removeItem(at: audioURL)
                        Log.app.info("cancelMeetingRecording: audio saved after cancel")
                    } else if !saved {
                        Log.app.warning("cancelMeetingRecording: library save failed — keeping in-progress audio")
                        if let ipId = cancelInProgressRecordingId {
                            _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                                id: ipId,
                                endedAt: stopTime,
                                durationSeconds: duration
                            )
                        }
                    }
                } else {
                    await meetingRecorderService.cancelRecording()
                    if let ipId = cancelInProgressRecordingId {
                        await discardLiveMeetingRow(id: ipId)
                    }
                }
            } catch {
                Log.app
                    .warning("cancelMeetingRecording: failed to save audio on cancel - \(error.localizedDescription)")
                await meetingRecorderService.cancelRecording()
                if let ipId = cancelInProgressRecordingId {
                    _ = RecordingsLibraryStorage.shared.markNeedsRecovery(id: ipId, endedAt: stopTime)
                }
            }
        } else {
            // Cancel meeting recorder without persisting
            await meetingRecorderService.cancelRecording()
            if let ipId = cancelInProgressRecordingId {
                await discardLiveMeetingRow(id: ipId)
            }
        }

        // Release the live transcript after the Flow panel returns to idle.
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

    /// Releases a meeting recording that died mid-session (capture error or
    /// system sleep) while keeping its audio on disk for recovery.
    func abandonMeetingForRecovery(
        startedAt: Date?,
        endedAt: Date = Date(),
        library: RecordingsLibraryStorage = .shared,
        releaseRecorder: (() async -> UUID?)? = nil
    ) async {
        Log.app.info("abandonMeetingForRecovery: releasing recorder, keeping audio for recovery")
        hotkeyService.unregisterChapterHotkey()
        EscapeCancelService.shared.deactivate()
        _ = await stopMeetingLiveTranscription()

        let releasedID: UUID? = if let releaseRecorder {
            await releaseRecorder()
        } else {
            await meetingRecorderService.releaseForRecovery()
        }
        if let releasedID {
            library.markNeedsRecovery(
                id: releasedID,
                endedAt: endedAt,
                durationSeconds: Self.recoveryDuration(startedAt: startedAt, endedAt: endedAt)
            )
        }

        releaseMeetingSleepActivityTokens()
        activeMeetingTranscriptionSessionID = nil
        activeMeetingTranscriptionProvider = nil
        activeMeetingStartRoute = nil
        activeMeetingTranslateTarget = nil
    }

    nonisolated static func resolveMeetingTranscriptionProvider(
        requestedProvider: TranscriptionProvider,
        hasStoredSession: Bool,
        cachedUsage: UsageResponse?
    ) -> TranscriptionProvider {
        requestedProvider == .cloud
            && UsageService.canOfferCloudTranscription(
                hasStoredSession: hasStoredSession,
                usage: cachedUsage
            ) ? .cloud : .local
    }

    func startMeetingRecording(
        provider requestedProvider: TranscriptionProvider,
        calendarMeeting: CalendarMeeting? = nil,
        translateTarget: String? = nil,
        recordOnly: Bool = false,
        startRoute: MeetingStartRoute? = nil,
        pipelineGeneration: UInt64? = nil,
        canStart: (() -> Bool)? = nil,
        ensureScreenRecordingPermission: @escaping () async -> Bool = {
            await PermissionManager.shared.ensureScreenRecordingPermission(context: .meetingRecording)
        },
        startRecorder: (() async throws -> Void)? = nil
    ) async {
        Log.app.info("startMeetingRecording: BEGIN")

        let generation = pipelineGeneration ?? meetingPipelineGeneration
        guard generation == meetingPipelineGeneration, !Task.isCancelled else { return }
        guard canStart?() ?? canStartRecording(kind: .meeting) else {
            if generation == meetingPipelineGeneration,
               appState.meetingRecordingState == .processing,
               activeMeetingTranscriptionSessionID == nil {
                appState.meetingRecordingState = .idle
                handleMeetingStateChange(.idle)
            }
            Log.app.info("startMeetingRecording: startup rejected")
            return
        }

        let sessionID = UUID()
        activeMeetingTranscriptionSessionID = sessionID
        // The user's own live engine: ElevenLabs (their key) or Apple on this Mac; calendar meetings too (8A).
        activeMeetingTranslateTarget = translateTarget
        // Calendar and Translate meeting starts pass only Cloud or Local: audio only, Whisper after Stop.
        activeMeetingStartRoute = startRoute ?? MeetingStartRoute(
            segment: requestedProvider == .cloud ? .cloud : .recordOnly,
            engine: requestedProvider == .cloud ? .didunyCloud : .whisper,
            provider: requestedProvider, recordOnly: recordOnly, localPreview: false, afterStopEngineID: nil
        )
        if translateTarget != nil || recordOnly {
            // Record only, or meeting translation on an on-device engine: no live stream; transcribed and translated after Stop.
            meetingRealtimeService = nil
        } else if let elevenLabs = makeElevenLabsMeetingService() {
            meetingRealtimeService = elevenLabs
        } else if let apple = makeAppleMeetingService() {
            meetingRealtimeService = apple
        } else {
            meetingRealtimeService = nil
        }
        meetingByokError = nil
        // Own engines stream live like Cloud (no Diduny sign-in needed) and never fall back to Cloud on their own.
        let provider: TranscriptionProvider = recordOnly ? .local
            : meetingRealtimeService != nil ? .cloud
            : Self.resolveMeetingTranscriptionProvider(
                requestedProvider: requestedProvider,
                hasStoredSession: AuthService.hasStoredSession,
                cachedUsage: UsageService.shared.cachedUsage
            )
        activeMeetingTranscriptionProvider = provider
        var didStart = false
        defer {
            if !didStart, activeMeetingTranscriptionSessionID == sessionID {
                activeMeetingTranscriptionSessionID = nil
                activeMeetingTranscriptionProvider = nil
                activeMeetingStartRoute = nil
            activeMeetingTranslateTarget = nil
                meetingRealtimeService = nil
            }
        }

        // Request screen capture permission on-demand
        let hasPermission = await ensureScreenRecordingPermission()
        guard !Task.isCancelled,
              activeMeetingTranscriptionSessionID == sessionID,
              appState.meetingRecordingState == .processing
        else {
            Log.app.info("startMeetingRecording: canceled during permission request")
            return
        }
        appState.screenCapturePermissionGranted = hasPermission

        guard hasPermission else {
            Log.app.warning("Screen capture permission not granted")
            await MainActor.run {
                appState.errorMessage = String(localized: "Screen recording permission required for meeting capture")
                appState.meetingRecordingState = .error
                handleMeetingStateChange(.error)
            }
            return
        }

        let cloudModeEnabled = provider == .cloud

        // Timed from after the permission check (which can block on a user
        // prompt) to the .recording state transition.
        let startMetrics = ConnectMetrics(label: "[Meeting] start")
        defer { startMetrics.finish() }

        // Prevent App Nap during meeting recording
        meetingActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Meeting recording in progress"
        )

        do {
            meetingRecorderService.audioSource = SettingsStorage.shared.meetingAudioSource
            meetingRecorderService.onRealtimeAudioData = nil
            wireMeetingRecorderStatusMessages()

            if meetingRecorderService.audioSource == .systemPlusMicrophone {
                let (device, didFallback) = audioDeviceManager.resolveDevice(
                    preferredUID: appState.preferredDeviceUID
                )
                appState.deviceFallbackWarning = nil
                if let device {
                    Log.app.info(
                        "startMeetingRecording: Device resolution result = \(device.name), transport=\(device.transportType.displayName), sampleRate=\(Int(device.sampleRate)), uid=\(device.uid)"
                    )
                }
                if didFallback, let name = device?.name {
                    Log.app.warning("startMeetingRecording: Preferred device unavailable, using \(name)")
                    appState.deviceFallbackWarning = "Selected microphone unavailable. Using \(name)"
                    if device?.isDefault == true {
                        appState.preferredDeviceUID = nil
                        Log.app
                            .info(
                                "startMeetingRecording: Cleared stale preferred microphone UID and switched to System Default"
                            )
                    }
                }
                meetingRecorderService.microphoneDevice = device
            } else {
                meetingRecorderService.microphoneDevice = nil
                appState.deviceFallbackWarning = nil
            }

            // Wire realtime transcription and start connecting BEFORE capture
            // setup, so the WS handshake overlaps ScreenCaptureKit/mic startup
            // instead of running after it. Audio captured before the socket is
            // up is buffered by CloudRealtimeService and flushed on connect —
            // recording never waits for the network.
            guard !Task.isCancelled, activeMeetingTranscriptionSessionID == sessionID else { return }
            let localPreview = !recordOnly && activeMeetingStartRoute?.localPreview == true
            let store = await setupMeetingLiveTranscription(cloudModeEnabled: cloudModeEnabled, localPreview: localPreview)
            let stillOwnsSession = activeMeetingTranscriptionSessionID == sessionID
            guard !Task.isCancelled,
                  stillOwnsSession,
                  appState.meetingRecordingState == .processing
            else {
                if stillOwnsSession {
                    _ = await stopMeetingLiveTranscription()
                    if let token = meetingActivityToken {
                        ProcessInfo.processInfo.endActivity(token)
                        meetingActivityToken = nil
                    }
                }
                return
            }

            startMetrics.begin(.recorderStart)
            if let startRecorder {
                try await startRecorder()
            } else {
                try await meetingRecorderService.startRecording()
            }
            startMetrics.end(.recorderStart)
            Log.app.info("Meeting recording started")

            // Only set recording state AFTER confirmed working
            let recordingStateAfterStart = appState.meetingRecordingState
            let ownsSessionAfterRecorderStart = activeMeetingTranscriptionSessionID == sessionID
            guard !Task.isCancelled,
                  ownsSessionAfterRecorderStart,
                  recordingStateAfterStart == .processing
            else {
                Log.app
                    .warning(
                        "startMeetingRecording: state changed during init (now \(recordingStateAfterStart)), aborting"
                    )
                if ownsSessionAfterRecorderStart {
                    _ = await stopMeetingLiveTranscription()
                    await meetingRecorderService.cancelRecording()
                    if let token = meetingActivityToken {
                        ProcessInfo.processInfo.endActivity(token)
                        meetingActivityToken = nil
                    }
                }
                return
            }
            await MainActor.run {
                appState.meetingRecordingState = .recording
                appState.meetingRecordingStartTime = Date()
                appState.liveTranscriptStore = store
                handleMeetingStateChange(.recording)
                let overlayStore = DictationOverlayController.shared.store
                if let controller = meetingEngineController {
                    if translateTarget != nil {
                        overlayStore.showRunningMeetingTranslation(engine: controller.machine.selected.engine)
                    } else {
                        overlayStore.showRunningMeeting(segment: controller.machine.selected.segment, engine: controller.machine.selected.engine)
                        // The start also seeds the after-Stop engine the Record only field shows.
                        overlayStore.meetingEngines[.recordOnly] = controller.machine.afterStopEngine
                    }
                    overlayStore.meetingSwitchHandler = meetingSwitchHandler(for: controller)
                }
                if !cloudModeEnabled {
                    updateRecordingFeedbackConnectionStatus(.connected, mode: .meeting)
                }
                if meetingRealtimeService != nil {
                    // Own live engines (ElevenLabs, Apple) give no speaker labels.
                    DictationOverlayController.shared.showInfoDuringRecording(
                        message: String(localized: "No speaker labels"), mode: .meeting, duration: 3)
                }
            }
            didStart = true

            // Library row from start — same UUID as InProgressRecordingStore.
            if let recordingId = meetingRecorderService.currentRecordingId {
                let startTime = appState.meetingRecordingStartTime ?? Date()
                let deviceInfo = meetingRecorderService.microphoneDevice.map {
                    RecordingDeviceInfo(
                        uid: $0.uid,
                        name: $0.name,
                        transportType: $0.transportType.displayName,
                        sampleRate: $0.sampleRate,
                        channelCount: $0.inputChannels,
                        wasDefaultRoute: $0.isDefault
                    )
                }
                _ = RecordingsLibraryStorage.shared.beginMeetingRecording(
                    id: recordingId,
                    type: .meeting,
                    createdAt: startTime,
                    sourceDevice: deviceInfo
                )
                if let calendarMeeting,
                   !RecordingsLibraryStorage.shared.linkCalendarMeeting(id: recordingId, meeting: calendarMeeting) {
                    DictationOverlayController.shared.showInfoDuringRecording(
                        message: String(localized: "Recording started, but the calendar link could not be saved."), mode: .meeting, duration: 4)
                }
            }

            startMetrics.finish(outcome: "ok")

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
            guard activeMeetingTranscriptionSessionID == sessionID else { return }
            if Task.isCancelled {
                _ = await stopMeetingLiveTranscription()
                await meetingRecorderService.cancelRecording()
                if let token = meetingActivityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    meetingActivityToken = nil
                }
                return
            }
            Log.app.error("Meeting recording failed: \(error)")

            // Abort the in-flight realtime connect — nothing will consume it.
            _ = await stopMeetingLiveTranscription()

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

    /// Builds the meeting's controller and fan-out and starts its first engine. Record only starts none.
    func setupMeetingLiveTranscription(
        cloudModeEnabled: Bool,
        localPreview: Bool
    ) async -> LiveTranscriptStore {
        let store = LiveTranscriptStore()
        let target = initialMeetingTarget(cloudModeEnabled: cloudModeEnabled, localPreview: localPreview)
        store.speakerLabels = target.engine == .didunyCloud || !target.isLive
        let afterStop: EngineID = if case let .afterStopOnly(engine) = target { engine }
            else { SettingsStorage.shared.modeDefaults.engine(for: .recordOnly) }
        let controller = makeMeetingEngineController(
            start: target, afterStop: afterStop, store: store, sessionID: activeMeetingTranscriptionSessionID, translation: nil
        )
        meetingEngineController = controller
        let fanOut = controller.fanOut
        meetingRecorderService.onRealtimeAudioData = { fanOut.deliver($0) }
        if target.isLive {
            Log.app.info("Meeting starts live on \(target.engine.rawValue, privacy: .public)")
            store.isActive = true
            if target.segment == .thisMac, target.engine == .whisper { store.connectionStatus = .connected }
        } else {
            Log.app.info("Meeting starts with no live text")
        }
        await controller.startInitial()
        return store
    }

    /// The start's engine as a target. Own engines stream live; Record only keeps its route's engine.
    private func initialMeetingTarget(cloudModeEnabled: Bool, localPreview: Bool) -> MeetingEngineTarget {
        if meetingRealtimeService is ElevenLabsRealtimeService { return .live(.elevenLabs) }
        if meetingRealtimeService is AppleLiveTranscriptionService { return .live(.appleSpeech) }
        let route = activeMeetingStartRoute
        switch RunningMeetingSession.segment(recordOnly: route?.recordOnly == true, cloudMode: cloudModeEnabled, localPreview: localPreview) {
        case .cloud: return .live(.didunyCloud)
        case .thisMac: return .live(.whisper)
        case .recordOnly:
            return .afterStopOnly(route?.segment == .recordOnly && route?.provider == .local ? route?.engine ?? .whisper
                : SettingsStorage.shared.modeDefaults.engine(for: .recordOnly))
        }
    }

    /// Ends the meeting's engines. `finalizeCloud` lets the current one finish (Stop); otherwise everything is cut
    /// at once and nothing may write status or text afterwards (Cancel, sleep, capture error).
    @discardableResult
    func stopMeetingLiveTranscription(finalizeCloud: Bool = false) async -> Bool {
        let controller = meetingEngineController
        meetingEngineController = nil
        let confirmed = await controller?.shutdown(finalize: finalizeCloud) ?? true
        meetingRecorderService.onRealtimeAudioData = nil
        meetingRealtimeService = nil
        if localMeetingStreamingService != nil {
            localMeetingStreamingService = nil
            appState.liveTranscriptStore?.connectionStatus = .disconnected
        }
        DictationOverlayController.shared.store.meetingSwitchHandler = nil
        return confirmed
    }

    @discardableResult
    func applyMeetingRealtimeConnectionStatus(
        _ status: RealtimeConnectionStatus,
        sessionID: UUID?,
        store: LiveTranscriptStore?
    ) -> Bool {
        guard let sessionID, activeMeetingTranscriptionSessionID == sessionID else { return false }
        store?.connectionStatus = status
        updateRecordingFeedbackConnectionStatus(status, mode: .meeting)
        if let id = meetingRecorderService.currentRecordingId {
            let detail: String? = switch status {
            case .connecting, .reconnecting:
                "Reconnecting…"
            case let .failed(message):
                message.isEmpty
                    ? "Live transcript interrupted — audio still recording"
                    : "Live transcript interrupted — audio still recording (\(message))"
            case .connected, .disconnected:
                nil
            }
            RecordingsLibraryStorage.shared.updateStatusDetail(id: id, detail: detail)
        }
        return true
    }

    /// Remembers an ElevenLabs failure for the current meeting; the recording itself continues.
    func recordMeetingByokError(_ error: Error, sessionID: UUID?) {
        guard let sessionID, activeMeetingTranscriptionSessionID == sessionID,
              let byokError = error as? ElevenLabsError else { return }
        meetingByokError = byokError
    }

    @discardableResult
    func fallBackMeetingToLocalIfUsageUnavailable(_ error: Error, sessionID: UUID?) -> Bool {
        guard let sessionID,
              activeMeetingTranscriptionSessionID == sessionID,
              activeMeetingTranscriptionProvider == .cloud,
              case .usageLimitExceeded = error as? RealtimeTranscriptionError
        else { return false }
        activeMeetingTranscriptionProvider = .local
        Log.app.info("Meeting transcription switched from Cloud to Local after usage rejection")
        return true
    }

    // MARK: - Stop Meeting Recording

    func addMeetingChapter() {
        guard appState.meetingRecordingState == .recording,
              let startTime = appState.meetingRecordingStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let chapterNumber = appState.meetingChapters.count + 1
        let chapter = MeetingChapter(timestampSeconds: elapsed, label: "Chapter \(chapterNumber)")
        appState.meetingChapters.append(chapter)
        DictationOverlayController.shared.showInfo(message: "Chapter \(chapterNumber) added", duration: 1.0)
        Log.app.info("Meeting chapter \(chapterNumber) added at \(elapsed)s")
    }

    func stopMeetingRecording() async {
        // Reentry guard: a second stop request (double-pressed shortcut, panel
        // button + shortcut) must not run the teardown pipeline twice. The
        // state flips to .processing synchronously below, so the next caller
        // lands in the cancel-while-processing branch instead.
        guard appState.meetingRecordingState == .recording else {
            let ignoredState = appState.meetingRecordingState
            Log.app.info("stopMeetingRecording: ignored, state is \(ignoredState)")
            return
        }

        Log.app.info("stopMeetingRecording: BEGIN")
        defer {
            activeMeetingTranscriptionSessionID = nil
            activeMeetingTranscriptionProvider = nil
            activeMeetingStartRoute = nil
            activeMeetingTranslateTarget = nil
            activeMeetingTranslationLanguagePair = nil
        }

        // Deactivate chapter bookmark hotkey
        hotkeyService.unregisterChapterHotkey()

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Capture recording start time for duration calculation
        let recordingStartTime = appState.meetingRecordingStartTime

        appState.meetingRecordingState = .processing
        handleMeetingStateChange(.processing)

        // Captured now: the session state is cleared when this stop finishes.
        let translateTarget = activeMeetingTranslateTarget
        let stopStartRoute = activeMeetingStartRoute

        // Finalize and disconnect real-time transcription (if active). A switch still connecting is cancelled first.
        let engineController = meetingEngineController
        let didReceiveRealtimeFinalization = await stopMeetingLiveTranscription(finalizeCloud: true)
        let history = engineController?.machine.history
        let afterStopEngine = engineController?.machine.afterStopEngine ?? .whisper

        // Next meeting start should hit a warm SCShareableContent cache.
        ShareableContentCache.shared.prewarm()

        // Mark store as no longer active
        let store = await MainActor.run { appState.liveTranscriptStore }
        await MainActor.run {
            store?.isActive = false
        }

        // Ensure App Nap prevention is always cleaned up
        defer {
            if let token = meetingActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                meetingActivityToken = nil
            }
        }

        // Track URLs for library save and cleanup in error/cancel paths
        var capturedAudioURL: URL?
        var originalWavURL: URL?
        let stopTime = Date()
        let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
        // Capture in-progress recording ID before stopRecording() clears it (RLR-M1).
        // Library row created at start uses this same UUID.
        let inProgressRecordingId = meetingRecorderService.currentRecordingId
        let recordingId = inProgressRecordingId ?? UUID()

        func cleanupTemporaryAudio() {
            if let wavURL = originalWavURL {
                try? FileManager.default.removeItem(at: wavURL)
            }
            if let audioURL = capturedAudioURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        func cleanupInProgressDirectory() {
            if let ipId = inProgressRecordingId {
                Task {
                    if let store = try? InProgressRecordingStore.sharedStore() {
                        try? await store.cleanup(recordingId: ipId)
                    }
                }
            }
        }

        // Whether the early library save succeeded (nil when the retention
        // policy skips saving) — read by the catch paths below.
        var librarySavedId: UUID?

        do {
            guard let audioURL = try await meetingRecorderService.stopRecording() else {
                throw MeetingRecorderError.recordingFailed
            }
            capturedAudioURL = audioURL

            Log.app.info("Meeting recording stopped")

            // The 2-channel file for speaker labels compresses alongside the mixed file.
            async let tracksAttached: Void = RecordingsLibraryStorage.shared.attachInProgressTracks(
                from: inProgressRecordingId,
                to: recordingId
            )

            // Compress WAV → FLAC before loading into memory (saves RAM and upload time)
            let compressedURL = await AudioCompressionService.compressToFLAC(wavURL: audioURL)
            let didCompress = compressedURL != audioURL
            if didCompress {
                originalWavURL = audioURL
                capturedAudioURL = compressedURL
            }

            // Finalize the live library row (same UUID as start). Fall back to
            // saveRecording when beginMeetingRecording never created a row.
            let hasLiveRow = RecordingsLibraryStorage.shared.recordings.contains { $0.id == recordingId }
            if hasLiveRow {
                let ok = RecordingsLibraryStorage.shared.finalizeInProgressRecording(
                    id: recordingId,
                    audioURL: compressedURL,
                    duration: duration,
                    endedAt: stopTime,
                    status: .processing,
                    forceSave: true
                )
                librarySavedId = ok ? recordingId : nil
            } else {
                librarySavedId = RecordingsLibraryStorage.shared.saveRecording(
                    id: recordingId,
                    audioURL: compressedURL,
                    type: .meeting,
                    duration: duration,
                    createdAt: recordingStartTime ?? stopTime,
                    forceSave: true
                )
                if librarySavedId != nil {
                    RecordingsLibraryStorage.shared.updateRecording(
                        id: recordingId,
                        status: .processing,
                        error: nil
                    )
                }
            }
            if librarySavedId == nil, let ipId = inProgressRecordingId {
                _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                    id: ipId,
                    endedAt: stopTime,
                    durationSeconds: duration
                )
            }
            await tracksAttached

            let realtimeText = await MainActor.run { store?.finalTranscriptText ?? "" }
            let liveEngine = history?.spans.last?.target.engine
            // ElevenLabs: the committed live text is the final transcript. Diduny: the acceptance guard.
            let liveTextAccepted = liveEngine == .didunyCloud
                ? shouldAcceptRealtimeTranscript(realtimeText, duration: duration, didReceiveFinalization: didReceiveRealtimeFinalization)
                : !realtimeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let plan = MeetingStopPlan.plan(
                history: history ?? MeetingEngineHistory(spans: []),
                afterStop: resolveAfterStopEngine(afterStopEngine),
                liveTextAccepted: liveTextAccepted
            )
            Log.app.notice("Meeting stop plan: \(String(describing: plan), privacy: .public)")

            let rawTranscript: GeneratedTranscript?
            if translateTarget == nil, case .keepLiveText = plan {
                rawTranscript = GeneratedTranscript(text: realtimeText)
                Log.app.info("Using real-time transcript (\(realtimeText.count) chars)")
            } else {
                rawTranscript = nil
            }
            let keptEngine: EngineID? = if case let .keepLiveText(engine) = plan { engine } else { nil }

            // Apply server-side cleanup (filler words, dedup, formatting).
            // Falls back to raw text silently if no auth / no network.
            let text: String? = if let rawTranscript {
                if rawTranscript.segments.contains(where: { $0.speaker != nil }) {
                    // Cleanup accepts plain text and can discard diarization structure.
                    TimedTranscriptRenderer.render(
                        segments: rawTranscript.segments,
                        fallbackText: rawTranscript.text
                    )
                } else {
                    await TranscriptCleanupService.shared.clean(
                        rawTranscript.text,
                        fillerWords: SettingsStorage.shared.fillerWords,
                        serverCleanup: keptEngine == .didunyCloud
                    )
                }
            } else {
                nil
            }

            let processingState = appState.meetingRecordingState
            guard processingState == .processing else {
                Log.app
                    .warning(
                        "stopMeetingRecording: state changed during processing (now \(processingState)), dropping result"
                    )
                if librarySavedId != nil {
                    RecordingsLibraryStorage.shared.updateRecording(
                        id: recordingId,
                        status: .unprocessed,
                        error: nil
                    )
                }
                cleanupTemporaryAudio()
                RecoveryStateManager.shared.clearState()
                return
            }

            await MainActor.run { DictationOverlayController.shared.setOutcomeRecordingID(librarySavedId) }

            if let text {
                clipboardService.copy(text: text, behavior: .raw)
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

                await MainActor.run {
                    appState.lastTranscription = text
                    appState.meetingRecordingState = .success
                    appState.meetingRecordingStartTime = nil
                    handleMeetingStateChange(.success)
                }
            } else {
                // Say "in background" only when the queue actually took the recording.
                var queued = false
                if let savedRecordingID = librarySavedId {
                    if let translateTarget {
                        queued = enqueueTranslateMeetingAfterStop(
                            savedRecordingID, target: translateTarget, history: history,
                            liveTexts: engineController?.liveTexts ?? [:], fallbackEngine: stopStartRoute?.engine ?? afterStopEngine,
                            afterStopEngine: afterStopEngine
                        )
                    } else if case let .wholeRecording(engine, modelID, _) = plan {
                        // C16: Diduny out of minutes at Stop retries on this Mac when a model is ready.
                        queued = RecordingQueueService.shared.enqueue(
                            [savedRecordingID],
                            action: .transcribeDiarize,
                            whisperModelOverride: engine == .whisper ? modelID : nil,
                            localFallbackOnUsageLimit: engine == .didunyCloud,
                            engineOverride: engine
                        )
                    }
                }
                await MainActor.run {
                    // Shown before .success so the panel switches in place instead of hiding.
                    if queued, translateTarget == nil {
                        DictationOverlayController.shared.showBackgroundHandoff(detail: plan.stopLine(preview: liveEngine))
                    } else if queued {
                        DictationOverlayController.shared.showBackgroundHandoff()
                    }
                    appState.lastTranscription = nil
                    appState.meetingRecordingState = .success
                    appState.meetingRecordingStartTime = nil
                    handleMeetingStateChange(.success)
                }
            }
            Log.app.info("stopMeetingRecording: SUCCESS")

            if let savedRecordingID = librarySavedId {
                if let text {
                    let segments = rawTranscript?.segments
                    RecordingsLibraryStorage.shared.completeTranscription(
                        id: recordingId,
                        status: .transcribed,
                        text: text,
                        segments: segments?.isEmpty == false ? segments : nil,
                        kind: .cloud,
                        provider: TranscriptionProvider.cloud.rawValue
                    )
                } else if RecordingQueueService.shared.isQueued(savedRecordingID)
                    || RecordingQueueService.shared.currentRecordingId == savedRecordingID
                {
                    // Already handed to the queue before the panel update.
                } else if recordingFailedAtHandOff(savedRecordingID) {
                    // Preflight refused and said why on the row; the audio stays.
                } else {
                    RecordingsLibraryStorage.shared.updateRecording(
                        id: recordingId,
                        status: .unprocessed,
                        error: nil
                    )
                    if case .saveOnly = plan {
                        DictationOverlayController.shared.showInfo(message: MeetingStopPlan.saveOnlyLine, duration: 3.0)
                    }
                }
            }
            // The pipeline is done reading compressedURL — the in-progress
            // directory (which contains it) can go now only after durable handoff.
            if librarySavedId != nil {
                cleanupInProgressDirectory()
                if didCompress {
                    try? FileManager.default.removeItem(at: audioURL)
                }
                try? FileManager.default.removeItem(at: compressedURL)
                RecoveryStateManager.shared.clearState()
            }

            if SettingsStorage.shared.playSoundOnCompletion {
                CompletionSound.play()
            }

            if let byokError = meetingByokError {
                meetingByokError = nil
                let savedID = librarySavedId
                Task { @MainActor in self.presentMeetingByokError(byokError, recordingID: savedID) }
            }

        } catch is CancellationError {
            Log.app.info("stopMeetingRecording: Cancelled")
            // The library entry (saved right after compression) stays — a
            // cancelled transcription must not throw away the meeting audio.
            // updateRecording is a no-op when the entry was never saved.
            if librarySavedId != nil {
                RecordingsLibraryStorage.shared.updateRecording(
                    id: recordingId,
                    status: .unprocessed,
                    error: nil
                )
                cleanupTemporaryAudio()
                cleanupInProgressDirectory()
                RecoveryStateManager.shared.clearState()
            } else if let ipId = inProgressRecordingId {
                _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                    id: ipId,
                    endedAt: stopTime,
                    durationSeconds: duration
                )
            }
            await MainActor.run {
                appState.meetingRecordingState = .idle
                appState.meetingRecordingStartTime = nil
                handleMeetingStateChange(.idle)
            }
            return
        } catch {
            Log.app.error("Meeting transcription failed: \(error)")

            if librarySavedId != nil {
                RecordingsLibraryStorage.shared.updateRecording(
                    id: recordingId,
                    status: .failed,
                    error: error.localizedDescription
                )
                cleanupInProgressDirectory()
                cleanupTemporaryAudio()
                RecoveryStateManager.shared.clearState()
            } else if let audioURL = capturedAudioURL {
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                let hasLiveRow = RecordingsLibraryStorage.shared.recordings.contains { $0.id == recordingId }
                let saved: Bool = if hasLiveRow {
                    RecordingsLibraryStorage.shared.finalizeInProgressRecording(
                        id: recordingId,
                        audioURL: audioURL,
                        duration: duration,
                        endedAt: stopTime,
                        status: .unprocessed,
                        forceSave: true
                    )
                } else {
                    RecordingsLibraryStorage.shared.saveRecording(
                        id: recordingId,
                        audioURL: audioURL,
                        type: .meeting,
                        duration: duration,
                        createdAt: recordingStartTime ?? stopTime,
                        forceSave: true
                    ) != nil
                }
                if saved {
                    cleanupInProgressDirectory()
                    cleanupTemporaryAudio()
                    RecoveryStateManager.shared.clearState()
                } else if let ipId = inProgressRecordingId {
                    _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                        id: ipId,
                        endedAt: stopTime,
                        durationSeconds: duration
                    )
                }
            }

            let processingState = appState.meetingRecordingState
            guard processingState == .processing else {
                Log.app
                    .warning(
                        "stopMeetingRecording: state changed during processing (now \(processingState)), dropping error"
                    )
                return
            }

            let userMessage: String = if let transcriptionError = error as? TranscriptionError {
                transcriptionError.localizedDescription
            } else {
                "Transcription failed: \(error.localizedDescription). Audio saved to Recordings."
            }

            await MainActor.run {
                appState.errorMessage = userMessage
                appState.meetingRecordingState = .error
                appState.meetingRecordingStartTime = nil
                handleMeetingStateChange(.error)
            }
        }

        Log.app.info("stopMeetingRecording: END")
    }

    private func shouldAcceptRealtimeTranscript(
        _ text: String,
        duration: TimeInterval,
        didReceiveFinalization: Bool
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if didReceiveFinalization { return true }

        // Short recordings often stop before Soniox emits an explicit finished frame.
        // For longer meetings, a tiny unfinalized transcript is usually partial and
        // should fall back to the async jobs pipeline for a complete result. Measure
        // visible content (trimmed) so a whitespace-padded transcript can't masquerade
        // as substantial.
        guard duration >= 30 else { return true }
        return trimmed.count >= 120
    }

    // MARK: - Escape Cancel Handler

    private func setupMeetingEscapeCancelHandler() {
        let escapeService = EscapeCancelService.shared
        guard SettingsStorage.shared.escapeCancelEnabled else {
            escapeService.deactivate()
            return
        }

        escapeService.onProgressEscape = { pressCount, _ in
            DictationOverlayController.shared.showInfoDuringRecording(
                message: SettingsStorage.shared.escapeCancelRepeatHint(afterPressCount: pressCount),
                mode: .meeting,
                duration: 1.5
            )
        }

        // On second shortcut press (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] keepAudio in
            Task { @MainActor in
                let shouldSaveAudio = keepAudio
                let cancellationTask = self?.cancelMeetingPipeline()
                await cancellationTask?.value
                let message = shouldSaveAudio ? "Recording cancelled and saved" : "Recording cancelled"
                DictationOverlayController.shared.showInfo(message: message)
            }
        }

        escapeService.activate()
    }

    /// Removes the live library row and in-progress directory after an explicit discard cancel.
    func discardLiveMeetingRow(id: UUID) async {
        if let recording = RecordingsLibraryStorage.shared.recordings.first(where: { $0.id == id }) {
            guard RecordingsLibraryStorage.shared.deleteCancelledInProgressRecording(recording) else {
                NSLog("[Diduny] Failed to discard cancelled meeting recording")
                return
            }
            return
        }
        if let store = try? InProgressRecordingStore.sharedStore() {
            try? await store.cleanup(recordingId: id)
        }
    }
}
