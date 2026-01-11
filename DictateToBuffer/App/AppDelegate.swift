import AppKit
import SwiftUI
import Combine
import AVFoundation
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    private var recordingWindow: NSWindow?

    let appState = AppState()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Services (exposed for SwiftUI access)

    lazy var audioDeviceManager = AudioDeviceManager()
    private lazy var audioRecorder = AudioRecorderService()
    private lazy var transcriptionService = SonioxTranscriptionService()
    private lazy var clipboardService = ClipboardService()
    private lazy var hotkeyService = HotkeyService()
    private lazy var pushToTalkService = PushToTalkService()
    private lazy var meetingHotkeyService = HotkeyService()
    private lazy var translationHotkeyService = HotkeyService()
    private lazy var translationPushToTalkService = PushToTalkService()
    @available(macOS 13.0, *)
    private lazy var meetingRecorderService = MeetingRecorderService()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupBindings()

        // Listen for push-to-talk key changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pushToTalkKeyChanged(_:)),
            name: .pushToTalkKeyChanged,
            object: nil
        )

        // Listen for hotkey changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyChanged(_:)),
            name: .hotkeyChanged,
            object: nil
        )

        // Listen for translation hotkey changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(translationHotkeyChanged(_:)),
            name: .translationHotkeyChanged,
            object: nil
        )

        // Listen for translation push-to-talk key changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(translationPushToTalkKeyChanged(_:)),
            name: .translationPushToTalkKeyChanged,
            object: nil
        )

        // Setup hotkey and push-to-talk immediately
        // Permissions will be requested on-demand when user tries to record
        setupHotkey()
        setupPushToTalk()
        setupTranslationHotkey()
        setupTranslationPushToTalk()

        // Check for API key
        if KeychainManager.shared.getSonioxAPIKey() == nil {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                openSettings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyService.unregister()
        pushToTalkService.stop()
        translationHotkeyService.unregister()
        translationPushToTalkService.stop()
    }

    // MARK: - Bindings

    private func setupBindings() {
        appState.$recordingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateRecordingWindow(for: state)
                self?.handleRecordingStateChange(state)
            }
            .store(in: &cancellables)

        appState.$meetingRecordingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleMeetingStateChange(state)
            }
            .store(in: &cancellables)

        appState.$translationRecordingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleTranslationStateChange(state)
            }
            .store(in: &cancellables)
    }

    private func handleRecordingStateChange(_ state: RecordingState) {
        switch state {
        case .success:
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if self.appState.recordingState == .success {
                    self.appState.recordingState = .idle
                }
            }
        case .error:
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.appState.recordingState == .error {
                    self.appState.recordingState = .idle
                }
            }
        default:
            break
        }
    }

    private func handleMeetingStateChange(_ state: MeetingRecordingState) {
        switch state {
        case .success:
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.appState.meetingRecordingState == .success {
                    self.appState.meetingRecordingState = .idle
                }
            }
        case .error:
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.appState.meetingRecordingState == .error {
                    self.appState.meetingRecordingState = .idle
                }
            }
        default:
            break
        }
    }

    private func handleTranslationStateChange(_ state: TranslationRecordingState) {
        switch state {
        case .success:
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if self.appState.translationRecordingState == .success {
                    self.appState.translationRecordingState = .idle
                }
            }
        case .error:
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.appState.translationRecordingState == .error {
                    self.appState.translationRecordingState = .idle
                }
            }
        default:
            break
        }
    }

    // MARK: - Recording Window (Minimal Pill)

    private func updateRecordingWindow(for state: RecordingState) {
        switch state {
        case .recording, .processing:
            showRecordingWindow()
        case .success:
            updateRecordingWindowContent()
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                self.hideRecordingWindow()
            }
        case .idle, .error:
            hideRecordingWindow()
        }
    }

    private func showRecordingWindow() {
        if recordingWindow == nil {
            let contentView = RecordingIndicatorView()
                .environmentObject(appState)

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = NSRect(x: 0, y: 0, width: 150, height: 40)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 150, height: 40),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.isMovableByWindowBackground = true

            // Position top-right
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.maxX - 160
                let y = screenFrame.maxY - 54
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }

            recordingWindow = window
        }

        recordingWindow?.orderFront(nil)
    }

    private func updateRecordingWindowContent() {
        // Content updates via appState binding
    }

    private func hideRecordingWindow() {
        recordingWindow?.orderOut(nil)
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        let settings = SettingsStorage.shared
        if let hotkey = settings.globalHotkey {
            try? hotkeyService.register(keyCombo: hotkey) { [weak self] in
                self?.toggleRecording()
            }
        }
    }

    // MARK: - Push to Talk

    private func setupPushToTalk() {
        let key = SettingsStorage.shared.pushToTalkKey
        pushToTalkService.selectedKey = key

        pushToTalkService.onKeyDown = { [weak self] in
            guard let self = self else { return }
            Task {
                await self.startRecordingIfIdle()
            }
        }

        pushToTalkService.onKeyUp = { [weak self] in
            guard let self = self else { return }
            Task {
                await self.stopRecordingIfRecording()
            }
        }

        if key != .none {
            pushToTalkService.start()
        }
    }

    @objc private func pushToTalkKeyChanged(_ notification: Notification) {
        guard let key = notification.object as? PushToTalkKey else { return }
        Log.app.info("Push-to-talk key changed to: \(key.displayName)")

        pushToTalkService.stop()
        pushToTalkService.selectedKey = key

        if key != .none {
            pushToTalkService.start()
        }
    }

    @objc private func hotkeyChanged(_ notification: Notification) {
        Log.app.info("Hotkey changed")

        // Unregister old hotkey
        hotkeyService.unregister()

        // Register new hotkey if set
        if let combo = notification.object as? KeyCombo {
            Log.app.info("Registering new hotkey: \(combo.displayString)")
            try? hotkeyService.register(keyCombo: combo) { [weak self] in
                self?.toggleRecording()
            }
        }
    }

    // MARK: - Translation Hotkey

    private func setupTranslationHotkey() {
        let settings = SettingsStorage.shared
        if let hotkey = settings.translationHotkey {
            try? translationHotkeyService.register(keyCombo: hotkey) { [weak self] in
                self?.toggleTranslationRecording()
            }
        }
    }

    @objc private func translationHotkeyChanged(_ notification: Notification) {
        Log.app.info("Translation hotkey changed")

        // Unregister old hotkey
        translationHotkeyService.unregister()

        // Register new hotkey if set
        if let combo = notification.object as? KeyCombo {
            Log.app.info("Registering new translation hotkey: \(combo.displayString)")
            try? translationHotkeyService.register(keyCombo: combo) { [weak self] in
                self?.toggleTranslationRecording()
            }
        }
    }

    // MARK: - Translation Push to Talk

    private func setupTranslationPushToTalk() {
        let key = SettingsStorage.shared.translationPushToTalkKey
        translationPushToTalkService.selectedKey = key

        translationPushToTalkService.onKeyDown = { [weak self] in
            guard let self = self else { return }
            Task {
                await self.startTranslationRecordingIfIdle()
            }
        }

        translationPushToTalkService.onKeyUp = { [weak self] in
            guard let self = self else { return }
            Task {
                await self.stopTranslationRecordingIfRecording()
            }
        }

        if key != .none {
            translationPushToTalkService.start()
        }
    }

    @objc private func translationPushToTalkKeyChanged(_ notification: Notification) {
        guard let key = notification.object as? PushToTalkKey else { return }
        Log.app.info("Translation push-to-talk key changed to: \(key.displayName)")

        translationPushToTalkService.stop()
        translationPushToTalkService.selectedKey = key

        if key != .none {
            translationPushToTalkService.start()
        }
    }

    private func startTranslationRecordingIfIdle() async {
        guard appState.translationRecordingState == .idle else {
            Log.app.info("startTranslationRecordingIfIdle: Not idle, ignoring")
            return
        }
        await startTranslationRecording()
    }

    private func stopTranslationRecordingIfRecording() async {
        guard appState.translationRecordingState == .recording else {
            Log.app.info("stopTranslationRecordingIfRecording: Not recording, ignoring")
            return
        }
        await stopTranslationRecording()
    }

    private func startRecordingIfIdle() async {
        guard appState.recordingState == .idle else {
            Log.app.info("startRecordingIfIdle: Not idle, ignoring")
            return
        }
        await startRecording()
    }

    private func stopRecordingIfRecording() async {
        guard appState.recordingState == .recording else {
            Log.app.info("stopRecordingIfRecording: Not recording, ignoring")
            return
        }
        await stopRecording()
    }

    // MARK: - Actions (exposed for SwiftUI and hotkeys)

    @objc func toggleRecording() {
        Log.app.info("toggleRecording called, current state: \(self.appState.recordingState)")
        Task {
            await performToggleRecording()
        }
    }

    private func performToggleRecording() async {
        Log.app.info("performToggleRecording: state = \(self.appState.recordingState)")
        switch appState.recordingState {
        case .idle:
            Log.app.info("State is idle, starting recording...")
            await startRecording()
        case .recording:
            Log.app.info("State is recording, stopping recording...")
            await stopRecording()
        default:
            Log.app.info("State is \(self.appState.recordingState), ignoring toggle")
            break
        }
    }

    private func startRecording() async {
        Log.app.info("startRecording: BEGIN")

        // Request microphone permission on-demand
        let micGranted = await PermissionManager.shared.ensureMicrophonePermission()
        appState.microphonePermissionGranted = micGranted

        guard micGranted else {
            Log.app.info("startRecording: Microphone permission not granted")
            await MainActor.run {
                appState.errorMessage = "Microphone access required"
                appState.recordingState = .error
            }
            return
        }

        guard let apiKey = KeychainManager.shared.getSonioxAPIKey(), !apiKey.isEmpty else {
            Log.app.info("startRecording: No API key found")
            await MainActor.run {
                appState.errorMessage = "Please add your Soniox API key in Settings"
                appState.recordingState = .error
            }
            return
        }
        Log.app.info("startRecording: API key found")

        // Determine device
        var device: AudioDevice?
        if appState.useAutoDetect {
            Log.app.info("startRecording: Using auto-detect, setting state to processing")
            await MainActor.run { appState.recordingState = .processing }
            device = await audioDeviceManager.autoDetectBestDevice()
            Log.app.info("startRecording: Auto-detected device: \(device?.name ?? "none")")
        } else if let deviceID = appState.selectedDeviceID {
            device = audioDeviceManager.availableDevices.first { $0.id == deviceID }
            Log.app.info("startRecording: Using selected device: \(device?.name ?? "none")")
        }

        Log.app.info("startRecording: Setting state to recording")
        await MainActor.run {
            appState.recordingState = .recording
            appState.recordingStartTime = Date()
        }
        Log.app.info("startRecording: State is now \(self.appState.recordingState)")

        do {
            Log.app.info("startRecording: Calling audioRecorder.startRecording()")
            try await audioRecorder.startRecording(
                device: device,
                quality: SettingsStorage.shared.audioQuality
            )
            Log.app.info("startRecording: Recording started successfully")
        } catch {
            Log.app.info("startRecording: ERROR - \(error.localizedDescription)")
            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.recordingState = .error
            }
        }
        Log.app.info("startRecording: END, final state = \(self.appState.recordingState)")
    }

    private func stopRecording() async {
        Log.app.info("stopRecording: BEGIN")

        await MainActor.run {
            appState.recordingState = .processing
        }
        Log.app.info("stopRecording: State set to processing")

        do {
            Log.app.info("stopRecording: Calling audioRecorder.stopRecording()")
            let audioData = try await audioRecorder.stopRecording()
            Log.app.info("stopRecording: Got audio data, size = \(audioData.count) bytes")

            guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                Log.app.info("stopRecording: No API key!")
                throw TranscriptionError.noAPIKey
            }

            Log.app.info("stopRecording: Calling transcription service")
            transcriptionService.apiKey = apiKey
            let text = try await transcriptionService.transcribe(audioData: audioData)
            Log.app.info("stopRecording: Transcription received: \(text.prefix(50))...")

            clipboardService.copy(text: text)
            Log.app.info("stopRecording: Text copied to clipboard")

            if SettingsStorage.shared.autoPaste {
                Log.app.info("stopRecording: Auto-pasting")
                do {
                    try await clipboardService.paste()
                } catch ClipboardError.accessibilityNotGranted {
                    Log.app.info("stopRecording: Accessibility permission needed")
                    PermissionManager.shared.showPermissionAlert(for: .accessibility)
                } catch {
                    Log.app.info("stopRecording: Paste failed - \(error.localizedDescription)")
                }
            }

            if SettingsStorage.shared.playSoundOnCompletion {
                Log.app.info("stopRecording: Playing sound")
                NSSound(named: .init("Funk"))?.play()
            }

            if SettingsStorage.shared.showNotification {
                Log.app.info("stopRecording: Showing notification")
                NotificationManager.shared.showSuccess(text: text)
            }

            await MainActor.run {
                appState.lastTranscription = text
                appState.recordingState = .success
            }
            Log.app.info("stopRecording: SUCCESS")

        } catch {
            Log.app.info("stopRecording: ERROR - \(error.localizedDescription)")
            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.recordingState = .error
            }
        }
        Log.app.info("stopRecording: END")
    }

    // MARK: - Meeting Recording

    @objc func toggleMeetingRecording() {
        Log.app.info("toggleMeetingRecording called, current state: \(self.appState.meetingRecordingState)")
        Task {
            await performToggleMeetingRecording()
        }
    }

    private func performToggleMeetingRecording() async {
        switch appState.meetingRecordingState {
        case .idle:
            await startMeetingRecording()
        case .recording:
            await stopMeetingRecording()
        default:
            Log.app.info("Meeting state is \(self.appState.meetingRecordingState), ignoring toggle")
        }
    }

    private func startMeetingRecording() async {
        Log.app.info("startMeetingRecording: BEGIN")

        guard #available(macOS 13.0, *) else {
            Log.app.info("Meeting recording requires macOS 13.0+")
            await MainActor.run {
                appState.errorMessage = "Meeting recording requires macOS 13.0 or later"
                appState.meetingRecordingState = .error
            }
            return
        }

        // Request screen capture permission on-demand
        let hasPermission = await PermissionManager.shared.ensureScreenRecordingPermission()
        appState.screenCapturePermissionGranted = hasPermission

        guard hasPermission else {
            Log.app.info("Screen capture permission not granted")
            await MainActor.run {
                appState.errorMessage = "Screen recording permission required for meeting capture"
                appState.meetingRecordingState = .error
            }
            return
        }

        guard let apiKey = KeychainManager.shared.getSonioxAPIKey(), !apiKey.isEmpty else {
            Log.app.info("No API key for meeting recording")
            await MainActor.run {
                appState.errorMessage = "Please add your Soniox API key in Settings"
                appState.meetingRecordingState = .error
            }
            return
        }

        await MainActor.run {
            appState.meetingRecordingState = .recording
            appState.meetingRecordingStartTime = Date()
        }

        do {
            meetingRecorderService.audioSource = SettingsStorage.shared.meetingAudioSource
            try await meetingRecorderService.startRecording()
            Log.app.info("Meeting recording started")
        } catch {
            Log.app.info("Meeting recording failed: \(error)")
            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.meetingRecordingState = .error
            }
        }
    }

    private func stopMeetingRecording() async {
        Log.app.info("stopMeetingRecording: BEGIN")

        guard #available(macOS 13.0, *) else { return }

        await MainActor.run {
            appState.meetingRecordingState = .processing
        }

        do {
            guard let audioURL = try await meetingRecorderService.stopRecording() else {
                throw MeetingRecorderError.recordingFailed
            }

            let audioData = try Data(contentsOf: audioURL)
            Log.app.info("Meeting recording stopped, size = \(audioData.count) bytes")

            guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                throw TranscriptionError.noAPIKey
            }

            Log.app.info("Transcribing meeting recording...")
            transcriptionService.apiKey = apiKey
            let text = try await transcriptionService.transcribe(audioData: audioData)
            Log.app.info("Meeting transcription received: \(text.prefix(100))...")

            clipboardService.copy(text: text)
            Log.app.info("stopMeetingRecording: Text copied to clipboard")

            if SettingsStorage.shared.autoPaste {
                Log.app.info("stopMeetingRecording: Auto-pasting")
                do {
                    try await clipboardService.paste()
                } catch ClipboardError.accessibilityNotGranted {
                    Log.app.info("stopMeetingRecording: Accessibility permission needed")
                    PermissionManager.shared.showPermissionAlert(for: .accessibility)
                } catch {
                    Log.app.info("stopMeetingRecording: Paste failed - \(error.localizedDescription)")
                }
            }

            if SettingsStorage.shared.playSoundOnCompletion {
                NSSound(named: .init("Funk"))?.play()
            }

            if SettingsStorage.shared.showNotification {
                NotificationManager.shared.showSuccess(text: "Meeting transcribed: \(text.prefix(100))...")
            }

            await MainActor.run {
                appState.lastTranscription = text
                appState.meetingRecordingState = .success
                appState.meetingRecordingStartTime = nil
            }

            // Clean up temp file
            try? FileManager.default.removeItem(at: audioURL)

        } catch {
            Log.app.info("Meeting transcription failed: \(error)")
            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.meetingRecordingState = .error
                appState.meetingRecordingStartTime = nil
            }
        }

        Log.app.info("stopMeetingRecording: END")
    }

    // MARK: - Translation Recording (EN <-> UK)

    @objc func toggleTranslationRecording() {
        Log.app.info("toggleTranslationRecording called, current state: \(self.appState.translationRecordingState)")
        Task {
            await performToggleTranslationRecording()
        }
    }

    private func performToggleTranslationRecording() async {
        switch appState.translationRecordingState {
        case .idle:
            await startTranslationRecording()
        case .recording:
            await stopTranslationRecording()
        default:
            Log.app.info("Translation state is \(self.appState.translationRecordingState), ignoring toggle")
        }
    }

    private func startTranslationRecording() async {
        Log.app.info("startTranslationRecording: BEGIN")

        // Request microphone permission on-demand
        let micGranted = await PermissionManager.shared.ensureMicrophonePermission()
        appState.microphonePermissionGranted = micGranted

        guard micGranted else {
            Log.app.info("startTranslationRecording: Microphone permission not granted")
            await MainActor.run {
                appState.errorMessage = "Microphone access required"
                appState.translationRecordingState = .error
            }
            return
        }

        guard let apiKey = KeychainManager.shared.getSonioxAPIKey(), !apiKey.isEmpty else {
            Log.app.info("startTranslationRecording: No API key found")
            await MainActor.run {
                appState.errorMessage = "Please add your Soniox API key in Settings"
                appState.translationRecordingState = .error
            }
            return
        }
        Log.app.info("startTranslationRecording: API key found")

        // Determine device
        var device: AudioDevice?
        if appState.useAutoDetect {
            Log.app.info("startTranslationRecording: Using auto-detect")
            await MainActor.run { appState.translationRecordingState = .processing }
            device = await audioDeviceManager.autoDetectBestDevice()
            Log.app.info("startTranslationRecording: Auto-detected device: \(device?.name ?? "none")")
        } else if let deviceID = appState.selectedDeviceID {
            device = audioDeviceManager.availableDevices.first { $0.id == deviceID }
            Log.app.info("startTranslationRecording: Using selected device: \(device?.name ?? "none")")
        }

        Log.app.info("startTranslationRecording: Setting state to recording")
        await MainActor.run {
            appState.translationRecordingState = .recording
            appState.translationRecordingStartTime = Date()
        }

        do {
            Log.app.info("startTranslationRecording: Starting audio recording")
            try await audioRecorder.startRecording(
                device: device,
                quality: SettingsStorage.shared.audioQuality
            )
            Log.app.info("startTranslationRecording: Recording started successfully")
        } catch {
            Log.app.info("startTranslationRecording: ERROR - \(error.localizedDescription)")
            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.translationRecordingState = .error
            }
        }
    }

    private func stopTranslationRecording() async {
        Log.app.info("stopTranslationRecording: BEGIN")

        await MainActor.run {
            appState.translationRecordingState = .processing
        }

        do {
            Log.app.info("stopTranslationRecording: Stopping audio recorder")
            let audioData = try await audioRecorder.stopRecording()
            Log.app.info("stopTranslationRecording: Got audio data, size = \(audioData.count) bytes")

            guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                Log.app.info("stopTranslationRecording: No API key!")
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
                    Log.app.info("stopTranslationRecording: Accessibility permission needed")
                    PermissionManager.shared.showPermissionAlert(for: .accessibility)
                } catch {
                    Log.app.info("stopTranslationRecording: Paste failed - \(error.localizedDescription)")
                }
            }

            if SettingsStorage.shared.playSoundOnCompletion {
                Log.app.info("stopTranslationRecording: Playing sound")
                NSSound(named: .init("Funk"))?.play()
            }

            if SettingsStorage.shared.showNotification {
                Log.app.info("stopTranslationRecording: Showing notification")
                NotificationManager.shared.showSuccess(text: "Translated: \(text.prefix(50))...")
            }

            await MainActor.run {
                appState.lastTranscription = text
                appState.translationRecordingState = .success
                appState.translationRecordingStartTime = nil
            }
            Log.app.info("stopTranslationRecording: SUCCESS")

        } catch {
            Log.app.info("stopTranslationRecording: ERROR - \(error.localizedDescription)")
            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.translationRecordingState = .error
                appState.translationRecordingStartTime = nil
            }
        }
        Log.app.info("stopTranslationRecording: END")
    }

    // MARK: - Device Selection (exposed for SwiftUI)

    func selectAutoDetect() {
        appState.useAutoDetect = true
        appState.selectedDeviceID = nil
    }

    func selectDevice(_ device: AudioDevice) {
        appState.useAutoDetect = false
        appState.selectedDeviceID = device.id
    }

    // MARK: - Settings

    func openSettings() {
        // Trigger settings opening via AppState (observed by SwiftUI)
        appState.shouldOpenSettings = true
    }

}
