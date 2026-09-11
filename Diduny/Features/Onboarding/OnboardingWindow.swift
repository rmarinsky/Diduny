import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private weak var appDelegate: AppDelegate?
    private var window: NSWindow?
    private var windowDelegate: OnboardingWindowDelegate?

    private init() {}

    func configure(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func showOnboarding() {
        guard let appDelegate else { return }
        OnboardingManager.shared.showSetupGuide()
        MainWindowController.shared.closeWindow()
        NSApp.setActivationPolicy(.regular)

        if let window {
            present(window)
            return
        }

        let rootView = OnboardingFlowView(
            appDelegate: appDelegate,
            onDismiss: { [weak self] in self?.finish() }
        )
        .preferredColorScheme(.dark)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("diduny.onboarding")
        window.title = String(localized: "Welcome to Diduny")
        window.contentView = NSHostingView(rootView: rootView)
        window.contentMinSize = NSSize(width: 760, height: 540)
        window.contentMaxSize = NSSize(width: 760, height: 540)
        window.isReleasedWhenClosed = false
        window.center()

        windowDelegate = OnboardingWindowDelegate { [weak self] in
            self?.finish(closeWindow: false)
        }
        window.delegate = windowDelegate
        self.window = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .milliseconds(150))
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    private func finish(closeWindow: Bool = true) {
        OnboardingManager.shared.hideSetupGuideForSession()
        if closeWindow {
            window?.delegate = nil
            window?.close()
        }
        window = nil
        windowDelegate = nil
        appDelegate?.showMainWindowAfterLaunch()
    }
}

private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_: Notification) {
        onClose()
    }
}

private enum OnboardingScreen: Int, CaseIterable {
    case welcome
    case capturePanel
    case permissions
    case signIn
    case practice
    case ready
}

private enum OnboardingTheme {
    static let accent = Color(red: 1, green: 0.36, blue: 0.49)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let border = Color.white.opacity(0.09)
}

private struct OnboardingFlowView: View {
    let appDelegate: AppDelegate
    let onDismiss: () -> Void

    @State private var screen: OnboardingScreen = .welcome
    @State private var onboarding = OnboardingManager.shared
    @State private var auth = AuthService.shared
    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var permissionInFlight: PermissionType?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var allPermissionsGranted: Bool {
        microphoneGranted && accessibilityGranted && screenRecordingGranted
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.horizontal, 36)
                .padding(.top, 18)

            ScrollView {
                screenContent
                    .frame(maxWidth: 620, minHeight: 390, alignment: .topLeading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 26)
            }

            footer
                .padding(.horizontal, 36)
                .padding(.bottom, 24)
        }
        .frame(width: 760, height: 540)
        .background(OnboardingTheme.background)
        .task { await refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermissions() }
        }
        .onChange(of: appDelegate.appState.recordingState) { _, state in
            if screen == .practice, onboarding.shouldShowReadyAfterPractice(recordingState: state) {
                move(to: .ready)
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingScreen.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item.rawValue <= screen.rawValue ? OnboardingTheme.accent : Color.white.opacity(0.12))
                    .frame(height: 3)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Onboarding progress")
        .accessibilityValue(String(
            format: String(localized: "Step %d of %d"),
            screen.rawValue + 1,
            OnboardingScreen.allCases.count
        ))
    }

    @ViewBuilder
    private var screenContent: some View {
        switch screen {
        case .welcome:
            welcomeScreen
        case .capturePanel:
            capturePanelScreen
        case .permissions:
            permissionsScreen
        case .signIn:
            signInScreen
        case .practice:
            practiceScreen
        case .ready:
            readyScreen
        }
    }

    private var welcomeScreen: some View {
        VStack(alignment: .leading, spacing: 22) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(
                    colors: [OnboardingTheme.accent, Color.pink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Meet Diduny")
                    .font(.largeTitle.bold())
                Text("The voice-first assistant that turns speech into finished work.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                feature("Dictate", icon: "waveform")
                feature("Translate", icon: "character.bubble")
                feature("Record meetings", icon: "record.circle")
            }
        }
    }

    private var capturePanelScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingHeading(
                title: "One control for your voice work",
                subtitle: "Move the pointer to Diduny to open quick actions, or use a shortcut from anywhere."
            )

            OnboardingPanelReveal {
                move(to: .permissions)
            }

            HStack(spacing: 12) {
                OnboardingShortcutBadge(keys: "⇧  ⇧", title: "Double Shift", subtitle: "Dictate")
                OnboardingShortcutBadge(keys: "⌥  ⌥", title: "Double Option", subtitle: "Translate automatically")
            }
        }
    }

    private var permissionsScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingHeading(
                title: "Allow Diduny to work with you",
                subtitle: "Each permission is used only for the feature described here."
            )

            VStack(spacing: 10) {
                OnboardingPermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: "Records your voice for dictation and meetings.",
                    isGranted: microphoneGranted,
                    isLoading: permissionInFlight == .microphone,
                    action: { request(.microphone) }
                )
                OnboardingPermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    detail: "Pastes completed text into the app you are using.",
                    isGranted: accessibilityGranted,
                    isLoading: permissionInFlight == .accessibility,
                    action: { request(.accessibility) }
                )
                OnboardingPermissionRow(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    detail: "Captures system audio when you record a meeting.",
                    isGranted: screenRecordingGranted,
                    isLoading: permissionInFlight == .screenRecording,
                    action: { request(.screenRecording) }
                )
            }
        }
    }

    private var signInScreen: some View {
        VStack(alignment: .leading, spacing: 22) {
            OnboardingHeading(
                title: "Sign in",
                subtitle: "Enter your email. We will send a six-digit code so you can use cloud dictation."
            )
            AccountSignInView()
                .padding(18)
                .background(OnboardingTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(OnboardingTheme.border, lineWidth: 1)
                }
        }
    }

    private var practiceScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingHeading(
                title: practiceTitle,
                subtitle: "Choose Transcribe below or press Double Shift, say a short phrase, then stop."
            )
            OnboardingCapturePanel(
                isSignedIn: true,
                recordingState: appDelegate.appState.recordingState,
                onTranscribe: startPractice,
                onMeeting: { appDelegate.toggleMeetingRecording() }
            )

            if appDelegate.appState.recordingState == .error {
                Label(
                    appDelegate.appState.errorMessage ?? String(localized: "Dictation failed. Try again."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var readyScreen: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 58))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            OnboardingHeading(
                title: "Diduny is ready",
                subtitle: "Your first dictation is saved in Recordings. Use Double Shift to dictate and Double Option to translate from anywhere."
            )
            OnboardingShortcutBadge(keys: "⇧  ⇧", title: "Double Shift", subtitle: "Start dictation")
            OnboardingShortcutBadge(keys: "⌥  ⌥", title: "Double Option", subtitle: "Translate automatically")
        }
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack {
            if screen != .ready {
                Button("Set up later", action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityHint(String(localized: "Closes setup for this launch without marking it complete"))
            }

            Spacer()

            if screen != .welcome, screen != .ready {
                Button("Back") {
                    move(to: OnboardingScreen(rawValue: screen.rawValue - 1) ?? .welcome)
                }
                .buttonStyle(.bordered)
            }

            OnboardingPrimaryButton(title: primaryButtonTitle, isEnabled: canContinue) {
                continueFlow()
            }
        }
    }

    private var primaryButtonTitle: LocalizedStringKey {
        switch screen {
        case .welcome: "Get started"
        case .capturePanel: "Continue"
        case .permissions: "Continue"
        case .signIn: "Continue"
        case .practice: "Try a dictation"
        case .ready: "Open Diduny"
        }
    }

    private var canContinue: Bool {
        switch screen {
        case .permissions: allPermissionsGranted
        case .signIn: auth.isLoggedIn
        case .practice:
            onboarding.canStartPractice(
                isAuthenticated: auth.isLoggedIn,
                microphoneGranted: microphoneGranted,
                accessibilityGranted: accessibilityGranted,
                screenRecordingGranted: screenRecordingGranted
            ) && (appDelegate.appState.recordingState == .idle || appDelegate.appState.recordingState == .error)
        case .welcome, .capturePanel, .ready: true
        }
    }

    private var practiceTitle: LocalizedStringKey {
        switch appDelegate.appState.recordingState {
        case .recording: "Now speak"
        case .processing: "Transcribing…"
        case .success: "That worked"
        case .error: "Let's try again"
        case .idle: "Try a short dictation"
        }
    }

    private func continueFlow() {
        switch screen {
        case .welcome: move(to: .capturePanel)
        case .capturePanel: move(to: .permissions)
        case .permissions: move(to: .signIn)
        case .signIn: move(to: .practice)
        case .practice: startPractice()
        case .ready: onDismiss()
        }
    }

    private func move(to destination: OnboardingScreen) {
        if reduceMotion {
            screen = destination
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                screen = destination
            }
        }
    }

    private func startPractice() {
        guard onboarding.canStartPractice(
            isAuthenticated: auth.isLoggedIn,
            microphoneGranted: microphoneGranted,
            accessibilityGranted: accessibilityGranted,
            screenRecordingGranted: screenRecordingGranted
        ) else {
            move(to: .permissions)
            return
        }
        appDelegate.toggleRecording()
    }

    private func feature(_ title: LocalizedStringKey, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(OnboardingTheme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func request(_ type: PermissionType) {
        guard permissionInFlight == nil else { return }
        permissionInFlight = type
        Task {
            switch type {
            case .microphone:
                if await PermissionManager.shared.requestMicrophonePermission() == false {
                    PermissionManager.shared.openSystemSettingsForPermission(.microphone)
                }
            case .accessibility:
                PermissionManager.shared.requestAccessibilityPermission()
                try? await Task.sleep(for: .milliseconds(700))
            case .screenRecording:
                if await PermissionManager.shared.requestScreenRecordingPermission() == false {
                    PermissionManager.shared.openSystemSettingsForPermission(.screenRecording)
                }
            }
            await refreshPermissions()
            permissionInFlight = nil
        }
    }

    private func refreshPermissions() async {
        await PermissionManager.shared.refreshStatus()
        let status = PermissionManager.shared.status
        microphoneGranted = status.microphone
        accessibilityGranted = status.accessibility
        screenRecordingGranted = status.screenRecording
    }
}

private struct OnboardingHeading: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingPrimaryButton: View {
    let title: LocalizedStringKey
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(minHeight: 32)
                .background(
                    isEnabled ? OnboardingTheme.accent : Color.secondary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct OnboardingPermissionRow: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let isGranted: Bool
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isGranted ? .green : OnboardingTheme.accent)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if isLoading {
                ProgressView().controlSize(.small)
            } else if isGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button("Allow", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(OnboardingTheme.accent)
            }
        }
        .padding(12)
        .background(OnboardingTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isGranted ? "Allowed" : "Not allowed")
    }
}

private struct OnboardingShortcutBadge: View {
    let keys: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(.body, design: .rounded, weight: .bold))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity)
        .background(OnboardingTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingPanelReveal: View {
    let onAction: () -> Void

    @State private var expanded = false
    @State private var cursorMoved = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            OnboardingProductionPanelPreview(onAction: onAction)
                .opacity(expanded ? 1 : 0)
                .scaleEffect(expanded ? 1 : 0.96, anchor: .topTrailing)
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)

            if !expanded {
                Capsule()
                    .fill(OnboardingTheme.accent)
                    .frame(width: 8, height: 72)
                    .accessibilityLabel("Diduny edge control")
            }

            Image(systemName: "cursorarrow")
                .font(.system(size: 23, weight: .medium))
                .offset(x: cursorMoved ? -6 : -150, y: cursorMoved ? 20 : 110)
                .opacity(expanded ? 0 : 1)
                .accessibilityHidden(true)
        }
        .frame(height: 250)
        .task {
            if reduceMotion {
                expanded = true
                return
            }
            withAnimation(.easeInOut(duration: 0.8)) { cursorMoved = true }
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { expanded = true }
        }
    }
}

private struct OnboardingProductionPanelPreview: View {
    let onAction: () -> Void
    @State private var model: EdgeCommandPanelModel

    @MainActor
    init(onAction: @escaping () -> Void) {
        self.onAction = onAction
        let pair = SettingsStorage.shared.resolveTranslationLanguagePair()
        _model = State(initialValue: EdgeCommandPanelModel(
            pairs: [pair],
            selectedPair: pair,
            provider: .local,
            isSignedIn: false
        ))
    }

    var body: some View {
        EdgeCommandExpandedView(
            model: model,
            liveStore: DictationOverlayController.shared.store,
            onAction: { _ in onAction() },
            onProvider: { _ in onAction() },
            onSignIn: onAction,
            onCopy: {},
            onStop: {},
            onDismissLive: {},
            onMinimizeLive: {},
            onStartMeetingSuggestion: { _ in },
            onDismissMeetingSuggestion: { _ in },
            onMeetingSuggestionsEnabled: { _ in },
            onCollapse: {},
            onDrag: {},
            onDragEnd: {}
        )
        .frame(width: 286, height: 250)
    }
}

private struct OnboardingCapturePanel: View {
    let isSignedIn: Bool
    let recordingState: RecordingState
    let onTranscribe: () -> Void
    let onMeeting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OnboardingTheme.accent)
                    .frame(width: 34, height: 34)
                    .overlay { Image(systemName: "mic.fill").foregroundStyle(.white) }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Diduny").font(.headline)
                    Text("What do you want to capture?").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !isSignedIn {
                    Button("Sign in", action: onTranscribe)
                        .buttonStyle(.bordered)
                        .tint(OnboardingTheme.accent)
                }
            }

            HStack(spacing: 7) {
                Text("Provider").font(.caption).foregroundStyle(.secondary)
                Label("Cloud", systemImage: isSignedIn ? "cloud" : "lock.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            HStack(spacing: 8) {
                captureAction(
                    title: transcriptionActionTitle,
                    subtitle: transcriptionActionSubtitle,
                    icon: recordingState == .recording ? "stop.circle.fill" : "waveform",
                    action: onTranscribe
                )
                captureAction(
                    title: "Record meeting",
                    subtitle: "System + mic",
                    icon: "record.circle",
                    action: onMeeting
                )
            }

            Label("Batch files & URLs", systemImage: "tray")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        }
    }

    private var transcriptionActionTitle: LocalizedStringKey {
        switch recordingState {
        case .recording: "Stop and transcribe"
        case .processing: "Transcribing…"
        case .success: "Transcribed"
        case .error: "Try again"
        case .idle: "Transcribe"
        }
    }

    private var transcriptionActionSubtitle: LocalizedStringKey {
        recordingState == .recording ? "Listening…" : "Voice → text"
    }

    private func captureAction(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(OnboardingTheme.accent)
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .padding(10)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(recordingState == .processing)
    }
}
