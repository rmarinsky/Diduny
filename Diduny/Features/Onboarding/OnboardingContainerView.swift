import AVFoundation
import SwiftUI

/// Main container that manages onboarding flow and step navigation
struct OnboardingContainerView: View {
    let onComplete: () -> Void

    @State private var currentStep: OnboardingStep = OnboardingManager.shared.currentStep

    var body: some View {
        ZStack {
            OnboardingBackgroundView()

            // Content based on current step
            Group {
                switch currentStep {
                case .welcome:
                    WelcomeStepView(onContinue: { goToStep(.microphonePermission) })

                case .microphonePermission:
                    PermissionStepView(
                        permission: .microphone,
                        onContinue: { goToStep(.accessibilityPermission) },
                        onSkip: { goToStep(.accessibilityPermission) }
                    )

                case .accessibilityPermission:
                    PermissionStepView(
                        permission: .accessibility,
                        onContinue: { goToStep(.screenRecordingPermission) },
                        onSkip: { goToStep(.screenRecordingPermission) }
                    )

                case .screenRecordingPermission:
                    PermissionStepView(
                        permission: .screenRecording,
                        onContinue: { goToStep(.shortcutSetup) },
                        onSkip: { goToStep(.shortcutSetup) }
                    )

                case .shortcutSetup:
                    ShortcutStepView(
                        onContinue: { goToStep(.apiSetup) },
                        onSkip: { goToStep(.apiSetup) }
                    )

                case .apiSetup:
                    APISetupStepView(
                        onContinue: { goToStep(.complete) },
                        onSkip: { goToStep(.complete) }
                    )

                case .complete:
                    CompleteStepView(onFinish: onComplete)
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .id(currentStep)
        }
        .onAppear {
            // Resume from saved step
            currentStep = OnboardingManager.shared.currentStep
        }
    }

    private func goToStep(_ step: OnboardingStep) {
        // Save progress
        OnboardingManager.shared.completeStep(currentStep)

        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = step
        }
    }
}

// MARK: - Welcome Step

struct WelcomeStepView: View {
    let onContinue: () -> Void

    @State private var showContent = false

    private let features = [
        ("mic.fill", "Voice to Text", "Transcribe speech instantly"),
        ("bolt.fill", "Fast & Accurate", "Powered by Soniox AI"),
        ("keyboard", "Double-tap to Record", "Quick hands-free control"),
        ("globe", "Works Everywhere", "Any app, any text field")
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

            // Title
            VStack(spacing: 8) {
                Text("Welcome to Diduny")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text("Your voice, transcribed instantly")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }

            // Features grid
            if showContent {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    ForEach(features, id: \.1) { icon, title, subtitle in
                        FeatureCard(icon: icon, title: title, subtitle: subtitle)
                    }
                }
                .padding(.horizontal, 30)
                .transition(.scale.combined(with: .opacity))
            }

            Spacer()

            // Buttons
            VStack(spacing: 12) {
                OnboardingPrimaryButton(title: "Get Started") {
                    onContinue()
                }

                Text("Takes about 2 minutes")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 30)
        }
        .padding(.horizontal, 20)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.2)) {
                showContent = true
            }
        }
    }
}

struct FeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Permission Step

enum OnboardingPermission {
    case microphone
    case accessibility
    case screenRecording

    var title: String {
        switch self {
        case .microphone: return "Microphone Access"
        case .accessibility: return "Accessibility Access"
        case .screenRecording: return "Screen Recording"
        }
    }

    var description: String {
        switch self {
        case .microphone:
            return "Diduny needs microphone access to hear your voice and transcribe it to text."
        case .accessibility:
            return "This allows Diduny to automatically paste transcribed text into any app."
        case .screenRecording:
            return "Optional: Enables recording meeting audio from Zoom, Teams, Google Meet, etc."
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic.fill"
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.on.rectangle"
        }
    }

    var isOptional: Bool {
        self == .screenRecording
    }

    var stepIndex: Int {
        switch self {
        case .microphone: return 0
        case .accessibility: return 1
        case .screenRecording: return 2
        }
    }
}

struct PermissionStepView: View {
    let permission: OnboardingPermission
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var isGranted = false
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 24) {
            // Progress
            ProgressDots(total: 6, current: permission.stepIndex + 1)
                .padding(.top, 30)

            Spacer()

            // Permission info
            VStack(spacing: 20) {
                // Icon with status
                ZStack {
                    Circle()
                        .fill(isGranted ? Color.green.opacity(0.1) : Color.accentColor.opacity(0.1))
                        .frame(width: 80, height: 80)

                    if isGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: permission.icon)
                            .font(.system(size: 32))
                            .foregroundColor(.accentColor)
                    }
                }

                VStack(spacing: 10) {
                    Text(permission.title)
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(permission.description)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                // Why needed explanation
                if !isGranted {
                    WhyNeededView(permission: permission)
                }
            }

            Spacer()

            // Buttons
            VStack(spacing: 12) {
                if isGranted {
                    OnboardingPrimaryButton(title: "Continue") {
                        onContinue()
                    }
                } else {
                    OnboardingPrimaryButton(title: isRequesting ? "Requesting..." : "Enable Access") {
                        requestPermission()
                    }
                    .disabled(isRequesting)

                    if permission.isOptional {
                        OnboardingSecondaryButton(title: "Skip for now") {
                            onSkip()
                        }
                    } else {
                        OnboardingSecondaryButton(title: "I'll do this later") {
                            onSkip()
                        }
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .padding(.horizontal, 20)
        .onAppear {
            checkPermission()
        }
    }

    private func checkPermission() {
        switch permission {
        case .microphone:
            isGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            isGranted = AXIsProcessTrusted()
        case .screenRecording:
            isGranted = PermissionManager.shared.status.screenRecording
        }
    }

    private func requestPermission() {
        isRequesting = true

        switch permission {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.isRequesting = false
                    self.isGranted = granted
                    // Bring window back to front after system dialog
                    self.bringWindowToFront()
                    if granted {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            self.onContinue()
                        }
                    }
                }
            }

        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            isRequesting = false

            // Poll for permission
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    DispatchQueue.main.async {
                        self.isGranted = true
                        self.bringWindowToFront()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            self.onContinue()
                        }
                    }
                }
            }

        case .screenRecording:
            Task {
                let granted = await PermissionManager.shared.requestScreenRecordingPermission()
                await MainActor.run {
                    isRequesting = false
                    isGranted = granted
                    bringWindowToFront()
                    if granted {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            onContinue()
                        }
                    } else {
                        // Open System Settings
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }

                        // Poll for permission
                        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                            Task {
                                let granted = await PermissionManager.shared.checkScreenRecordingPermission()
                                if granted {
                                    timer.invalidate()
                                    await MainActor.run {
                                        self.isGranted = true
                                        self.bringWindowToFront()
                                        Task { @MainActor in
                                            try? await Task.sleep(for: .milliseconds(300))
                                            self.onContinue()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func bringWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        // Find and focus the onboarding window
        for window in NSApp.windows {
            if window.title == "Welcome to Diduny" {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
}

struct WhyNeededView: View {
    let permission: OnboardingPermission

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)

            Text(whyText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var whyText: String {
        switch permission {
        case .microphone:
            return "Your audio is sent to Soniox for transcription and not stored."
        case .accessibility:
            return "Without this, you'll need to manually paste (⌘V) after transcription."
        case .screenRecording:
            return "Only used when you explicitly start a meeting recording."
        }
    }
}

// MARK: - Shortcut Step

struct ShortcutStepView: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var selectedKey: PushToTalkKey = SettingsStorage.shared.pushToTalkKey
    @State private var testStatus: TestStatus = .idle
    @State private var lastTapTime: Date?

    private let availableKeys: [PushToTalkKey] = [.rightShift, .rightCommand, .rightOption]
    private let doubleTapInterval: TimeInterval = 0.4

    enum TestStatus {
        case idle, firstTap, recording, stopped
    }

    var body: some View {
        VStack(spacing: 24) {
            ProgressDots(total: 6, current: 4)
                .padding(.top, 30)

            Spacer()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: 70, height: 70)

                    Image(systemName: "keyboard")
                        .font(.system(size: 28))
                        .foregroundColor(.accentColor)
                }

                VStack(spacing: 8) {
                    Text("Quick Recording Shortcut")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Double-tap a key to start recording,\ndouble-tap again to stop.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Key selection
                VStack(spacing: 12) {
                    Text("Choose your key:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        ForEach(availableKeys, id: \.self) { key in
                            KeyOptionButton(key: key, isSelected: selectedKey == key) {
                                selectedKey = key
                                testStatus = .idle
                            }
                        }
                    }
                }

                // Test area
                TestAreaView(selectedKey: selectedKey, testStatus: $testStatus, lastTapTime: $lastTapTime)
            }

            Spacer()

            VStack(spacing: 12) {
                OnboardingPrimaryButton(title: "Select & Continue") {
                    saveSettings()
                    onContinue()
                }

                OnboardingSecondaryButton(title: "Skip") {
                    onSkip()
                }
            }
            .padding(.bottom, 30)
        }
        .padding(.horizontal, 20)
        .onAppear {
            setupKeyMonitor()
        }
    }

    private func setupKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleKeyEvent(event)
            return event
        }

        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handleKeyEvent(event)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard isSelectedKey(event), isKeyPressed(event) else { return }

        let now = Date()

        if let lastTap = lastTapTime, now.timeIntervalSince(lastTap) < doubleTapInterval {
            // Double tap
            withAnimation(.easeInOut(duration: 0.2)) {
                if testStatus == .recording {
                    testStatus = .stopped
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        if testStatus == .stopped { testStatus = .idle }
                    }
                } else {
                    testStatus = .recording
                }
            }
            lastTapTime = nil
        } else {
            lastTapTime = now
            if testStatus != .recording {
                withAnimation { testStatus = .firstTap }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(Int(doubleTapInterval * 1000) + 100))
                    if testStatus == .firstTap { withAnimation { testStatus = .idle } }
                }
            }
        }
    }

    private func isSelectedKey(_ event: NSEvent) -> Bool {
        switch selectedKey {
        case .rightShift: return event.keyCode == 60
        case .rightCommand: return event.keyCode == 54
        case .rightOption: return event.keyCode == 61
        default: return false
        }
    }

    private func isKeyPressed(_ event: NSEvent) -> Bool {
        switch selectedKey {
        case .rightShift: return event.modifierFlags.contains(.shift)
        case .rightCommand: return event.modifierFlags.contains(.command)
        case .rightOption: return event.modifierFlags.contains(.option)
        default: return false
        }
    }

    private func saveSettings() {
        SettingsStorage.shared.pushToTalkKey = selectedKey
        SettingsStorage.shared.handsFreeModeEnabled = true
        NotificationCenter.default.post(name: .pushToTalkKeyChanged, object: selectedKey)
    }
}

struct TestAreaView: View {
    let selectedKey: PushToTalkKey
    @Binding var testStatus: ShortcutStepView.TestStatus
    @Binding var lastTapTime: Date?

    var body: some View {
        VStack(spacing: 10) {
            Text("Try it now:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    KeyCapView(symbol: selectedKey.symbol, isPressed: testStatus == .firstTap || testStatus == .recording)
                    Text("×2")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(statusColor)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(testStatus == .recording ? Color.red : Color.gray.opacity(0.2), lineWidth: testStatus == .recording ? 2 : 1)
            )
        }
        .padding(.horizontal, 30)
    }

    private var statusColor: Color {
        switch testStatus {
        case .idle: return .gray
        case .firstTap: return .orange
        case .recording: return .red
        case .stopped: return .green
        }
    }

    private var statusText: String {
        switch testStatus {
        case .idle: return "Double-tap \(selectedKey.symbol) to test"
        case .firstTap: return "Tap again quickly..."
        case .recording: return "Recording! Double-tap to stop"
        case .stopped: return "Success!"
        }
    }
}

// MARK: - API Setup Step

struct APISetupStepView: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var apiKey = ""
    @State private var isTesting = false
    @State private var testResult: TestResult = .none

    enum TestResult {
        case none, success, error(String)
    }

    var body: some View {
        VStack(spacing: 24) {
            ProgressDots(total: 6, current: 5)
                .padding(.top, 30)

            Spacer()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: 70, height: 70)

                    Image(systemName: "key.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.accentColor)
                }

                VStack(spacing: 8) {
                    Text("Connect to Soniox")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Enter your Soniox API key for transcription.\nGet a free key at soniox.com")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                // API Key input
                VStack(spacing: 12) {
                    SecureField("Paste your API key here", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)

                    // Status
                    if case let .error(message) = testResult {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    } else if case .success = testResult {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("API key saved!")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }

                    Link(destination: URL(string: "https://soniox.com")!) {
                        HStack(spacing: 4) {
                            Text("Get a free API key")
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                        }
                        .font(.subheadline)
                    }
                }
            }

            Spacer()

            VStack(spacing: 12) {
                OnboardingPrimaryButton(title: apiKey.isEmpty ? "Skip for now" : "Save & Continue") {
                    if apiKey.isEmpty {
                        onSkip()
                    } else {
                        saveAndContinue()
                    }
                }
                .disabled(isTesting)
            }
            .padding(.bottom, 30)
        }
        .padding(.horizontal, 20)
        .onAppear {
            if let existing = KeychainManager.shared.getSonioxAPIKey() {
                apiKey = existing
            }
        }
    }

    private func saveAndContinue() {
        guard !apiKey.isEmpty else {
            onSkip()
            return
        }

        isTesting = true
        Task {
            do {
                try KeychainManager.shared.setSonioxAPIKey(apiKey)
                await MainActor.run {
                    isTesting = false
                    testResult = .success
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        onContinue()
                    }
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testResult = .error("Failed to save")
                }
            }
        }
    }
}

// MARK: - Complete Step

struct CompleteStepView: View {
    let onFinish: () -> Void

    @State private var showConfetti = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Success icon
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.green)
            }
            .scaleEffect(showConfetti ? 1 : 0.5)
            .opacity(showConfetti ? 1 : 0)

            VStack(spacing: 12) {
                Text("You're all set!")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text("Start transcribing by double-tapping\nyour shortcut key, or use the menu bar.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Quick tips
            VStack(alignment: .leading, spacing: 12) {
                TipRow(icon: "keyboard", text: "Double-tap your key to start/stop recording")
                TipRow(icon: "menubar.rectangle", text: "Click the menu bar icon for more options")
                TipRow(icon: "gearshape", text: "Access settings anytime from the menu")
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)

            Spacer()

            OnboardingPrimaryButton(title: "Start Using Diduny") {
                onFinish()
            }
            .padding(.bottom, 30)
        }
        .padding(.horizontal, 20)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showConfetti = true
            }
        }
    }
}

struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            Text(text)
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    OnboardingContainerView(onComplete: {})
        .frame(width: 550, height: 580)
}
