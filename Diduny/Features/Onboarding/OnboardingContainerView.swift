import AVFoundation
import ApplicationServices
import SwiftUI

// MARK: - Style & Typography Tokens

private enum OnboardingStyle {
    // Colors
    static let brandBlue = Color(red: 0.15, green: 0.51, blue: 0.95)
    static let brandBlueDark = Color(red: 0.09, green: 0.41, blue: 0.84)
    static let panelBlue = Color(red: 0.80, green: 0.88, blue: 0.98)
    static let titleColor = Color(red: 0.16, green: 0.24, blue: 0.50)

    // Typography tokens (design doc §2)
    static let display   = Font.system(size: 30, weight: .bold)
    static let title     = Font.system(size: 22, weight: .bold)
    static let subtitle  = Font.system(size: 16, weight: .regular)
    static let body      = Font.system(size: 13, weight: .regular)
    static let cardTitle = Font.system(size: 15, weight: .bold)
    static let cardBody  = Font.system(size: 13, weight: .regular)
    static let button    = Font.system(size: 13, weight: .semibold)
    static let textAction = Font.system(size: 13, weight: .semibold)
    // `header` token defined for completeness; unused by Phase 1 after custom header removal.
    static let header    = Font.system(size: 13, weight: .semibold)
    static let label     = Font.system(size: 12, weight: .medium)
    static let tip       = Font.system(size: 13, weight: .regular)
    static let caption   = Font.system(size: 12, weight: .regular)
}

// MARK: - ProgressDots dot index helper

private func dotIndex(for step: OnboardingStep) -> Int? {
    switch step {
    case .microphonePermission, .accessibilityPermission: return 0
    case .screenRecordingPermission: return 1
    case .shortcutSetup: return 2
    case .complete: return 3
    default: return nil
    }
}

// MARK: - Main Container

/// Main container that manages onboarding flow and step navigation.
/// Supports both the full welcome tour and the mini-flow (Permissions Check).
struct OnboardingContainerView: View {
    let onComplete: () -> Void

    @State private var currentStep: OnboardingStep = OnboardingManager.shared.currentStep

    /// Mini-flow step list. Non-nil when showing Permissions Check.
    private var miniFlowSteps: [OnboardingStep]? {
        OnboardingManager.shared.miniFlowSteps
    }

    // MARK: - ProgressDots wiring

    private var showProgressDots: Bool {
        guard currentStep != .welcome else { return false }
        if let steps = miniFlowSteps {
            return steps.count > 1
        }
        return true
    }

    private var progressTotal: Int {
        if let steps = miniFlowSteps { return steps.count }
        // Full flow: mic/access(0), screenRecording(1), shortcut(2), complete(3) — 4 dots
        return 4
    }

    private var progressCurrent: Int {
        if let steps = miniFlowSteps {
            return steps.firstIndex(of: currentStep) ?? 0
        }
        return dotIndex(for: currentStep) ?? 0
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            OnboardingBackgroundView()

            VStack(spacing: 0) {
                // ProgressDots — below native titlebar, hidden on Welcome
                if showProgressDots {
                    HStack {
                        ProgressDots(total: progressTotal, current: progressCurrent)
                            .accessibilityLabel("Step \(progressCurrent + 1) of \(progressTotal)")
                            .accessibilityHidden(false)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Group {
                    switch currentStep {
                    case .welcome:
                        WelcomeStepView(
                            jumpToStep: miniFlowSteps?.first,
                            onContinue: { target in
                                navigate(to: target ?? .microphonePermission)
                            }
                        )

                    case .microphonePermission, .accessibilityPermission:
                        SetupComputerStepView(
                            onBack: { navigate(to: .welcome, markCurrentAsComplete: false) },
                            onContinue: { navigate(to: nextStep(after: .microphonePermission)) },
                            onSkip: { navigate(to: nextStep(after: .microphonePermission),
                                               markCurrentAsComplete: false) }
                        )

                    case .screenRecordingPermission:
                        ScreenRecordingStepView(
                            onBack: { navigate(to: prevStep(before: .screenRecordingPermission),
                                               markCurrentAsComplete: false) },
                            onContinue: { navigate(to: nextStep(after: .screenRecordingPermission)) },
                            onSkip: {
                                SettingsStorage.shared.userDeclinedScreenRecording = true
                                navigate(to: nextStep(after: .screenRecordingPermission),
                                         markCurrentAsComplete: false)
                            }
                        )

                    case .shortcutSetup:
                        ShortcutStepView(
                            onBack: { navigate(to: .screenRecordingPermission,
                                               markCurrentAsComplete: false) },
                            onContinue: { navigate(to: nextStep(after: .shortcutSetup)) },
                            onSkip: { navigate(to: nextStep(after: .shortcutSetup),
                                               markCurrentAsComplete: false) }
                        )

                    case .apiSetup:
                        // Deprecated — see docs/decisions/0008-onboarding-step-enum-stability.md
                        CompleteStepView(onFinish: onComplete)

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
            .padding(10)
        }
        .onAppear(perform: restoreCurrentStep)
    }

    // MARK: - Navigation helpers

    private func restoreCurrentStep() {
        let savedStep = OnboardingManager.shared.currentStep
        if savedStep == .accessibilityPermission {
            currentStep = .microphonePermission
        } else {
            currentStep = savedStep
        }
    }

    private func navigate(to step: OnboardingStep, markCurrentAsComplete: Bool = true) {
        if markCurrentAsComplete {
            OnboardingManager.shared.completeStep(currentStep)
        }
        OnboardingManager.shared.currentStep = step
        withAnimation(.easeInOut(duration: 0.28)) {
            currentStep = step
        }
    }

    /// Next step in mini-flow context or full flow.
    private func nextStep(after step: OnboardingStep) -> OnboardingStep {
        if let steps = miniFlowSteps {
            if let idx = steps.firstIndex(of: step), idx + 1 < steps.count {
                return steps[idx + 1]
            }
            // Last step in mini-flow — complete
            return .complete
        }
        // Full flow order
        switch step {
        case .microphonePermission: return .screenRecordingPermission
        case .screenRecordingPermission: return .shortcutSetup
        case .shortcutSetup: return .complete
        default: return .complete
        }
    }

    private func prevStep(before step: OnboardingStep) -> OnboardingStep {
        if let steps = miniFlowSteps {
            if let idx = steps.firstIndex(of: step), idx > 0 {
                return steps[idx - 1]
            }
            return steps.first ?? .microphonePermission
        }
        switch step {
        case .screenRecordingPermission: return .microphonePermission
        case .shortcutSetup: return .screenRecordingPermission
        default: return .welcome
        }
    }
}

// MARK: - Shared Layout

private struct OnboardingWindowFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingSplitFrame<Left: View, Right: View>: View {
    let left: Left
    let right: Right

    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.left = left()
        self.right = right()
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 600
            Group {
                if isWide {
                    HStack(spacing: 0) {
                        ScrollView(.vertical, showsIndicators: false) {
                            left
                                .frame(maxWidth: 360, alignment: .topLeading)
                        }
                        .frame(width: proxy.size.width * 0.50)
                        .background(Color(nsColor: .windowBackgroundColor))

                        ScrollView(.vertical, showsIndicators: false) {
                            right
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(width: proxy.size.width * 0.50)
                        .background(OnboardingStyle.panelBlue)
                    }
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 16) {
                            left
                            right
                        }
                        .frame(maxWidth: 480)
                        .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isWide)
        }
    }
}

// MARK: - Shared Buttons

private struct OnboardingMainButton: View {
    let title: String
    let disabled: Bool
    let action: () -> Void

    init(title: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(OnboardingStyle.button)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .padding(.horizontal, 16)
                .background(disabled ? OnboardingStyle.brandBlue.opacity(0.45)
                                     : OnboardingStyle.brandBlueDark)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct OnboardingTextAction: View {
    let title: String
    let icon: String?
    let action: () -> Void

    init(title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(OnboardingStyle.textAction)
            .foregroundColor(OnboardingStyle.titleColor)
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionActionButton: View {
    let title: String
    let disabled: Bool
    let action: () -> Void

    init(title: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(OnboardingStyle.button)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(disabled ? OnboardingStyle.brandBlue.opacity(0.45)
                                     : OnboardingStyle.brandBlueDark)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct PermissionOutlineButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(OnboardingStyle.button)
                .foregroundColor(OnboardingStyle.brandBlueDark)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Color.white.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(OnboardingStyle.brandBlueDark.opacity(0.65), lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionCardView: View {
    let number: Int
    let title: String
    let description: String
    let granted: Bool
    let isRequesting: Bool
    let onAllow: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(granted ? Color.green : OnboardingStyle.brandBlueDark)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(OnboardingStyle.cardTitle)
                        .foregroundColor(OnboardingStyle.titleColor)

                    Text(description)
                        .font(OnboardingStyle.cardBody)
                        .foregroundColor(OnboardingStyle.titleColor.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if granted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                    Text("Granted")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.green)
                .accessibilityLabel("Permission granted")
            } else {
                HStack(spacing: 12) {
                    PermissionActionButton(
                        title: isRequesting ? "Requesting..." : "Allow",
                        disabled: isRequesting,
                        action: onAllow
                    )
                    .accessibilityHint(isRequesting ? "Permission is being requested" : "")
                    PermissionOutlineButton(title: "Open settings", action: onOpenSettings)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Welcome Step

struct WelcomeStepView: View {
    /// If non-nil, the Continue button jumps to this step (skipping already-granted permissions).
    let jumpToStep: OnboardingStep?
    let onContinue: (OnboardingStep?) -> Void

    @State private var showButton = false

    var body: some View {
        OnboardingWindowFrame {
            ZStack {
                LinearGradient(
                    colors: [OnboardingStyle.brandBlue, OnboardingStyle.brandBlueDark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: 24) {
                    Spacer()

                    Text("Any language. Any voice.\nInstantly.")
                        .font(OnboardingStyle.display)
                        .foregroundColor(.white.opacity(0.96))
                        .multilineTextAlignment(.center)
                        .lineSpacing(6)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 20)

                    if showButton {
                        Button(action: { onContinue(jumpToStep) }) {
                            Text("Start using Diduny")
                                .font(OnboardingStyle.button)
                                .foregroundColor(OnboardingStyle.brandBlueDark)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.94))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }

                    Spacer()
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.1)) {
                showButton = true
            }
        }
    }
}

// MARK: - Permissions Setup Step (mic + accessibility)

struct SetupComputerStepView: View {
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var isRequestingMicrophone = false
    @State private var isRequestingAccessibility = false
    @State private var didAutoAdvance = false

    private let refreshTimer = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    var body: some View {
        OnboardingSplitFrame {
            VStack(alignment: .leading, spacing: 16) {
                Spacer(minLength: 0)

                Text("Set up your computer")
                    .font(OnboardingStyle.title)
                    .foregroundColor(OnboardingStyle.titleColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text("Enable permissions to start using Diduny.")
                    .font(OnboardingStyle.subtitle)
                    .foregroundColor(OnboardingStyle.titleColor.opacity(0.92))

                OnboardingMainButton(title: "Next", disabled: !canContinue) {
                    onContinue()
                }
                .padding(.top, 8)

                Spacer(minLength: 0)

                HStack(spacing: 24) {
                    OnboardingTextAction(title: "Back", icon: "arrow.uturn.left", action: onBack)
                    OnboardingTextAction(title: "Skip", action: onSkip)
                }
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        } right: {
            VStack(spacing: 12) {
                PermissionCardView(
                    number: 1,
                    title: "Allow Diduny to use your microphone.",
                    description: "This allows Diduny to capture your speech for dictation and translation.",
                    granted: microphoneGranted,
                    isRequesting: isRequestingMicrophone,
                    onAllow: requestMicrophonePermission,
                    onOpenSettings: { openSystemSettings(anchor: "Privacy_Microphone") }
                )

                PermissionCardView(
                    number: 2,
                    title: "Allow Diduny to insert spoken words.",
                    description: "This allows Diduny to insert transcribed words into text fields.",
                    granted: accessibilityGranted,
                    isRequesting: isRequestingAccessibility,
                    onAllow: requestAccessibilityPermission,
                    onOpenSettings: { openSystemSettings(anchor: "Privacy_Accessibility") }
                )

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .onAppear(perform: refreshPermissionStatus)
        .onReceive(refreshTimer) { _ in
            refreshPermissionStatus()
        }
    }

    private var canContinue: Bool {
        microphoneGranted && accessibilityGranted
    }

    private func refreshPermissionStatus() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()

        // Both permissions granted — advance automatically so the user
        // doesn't have to hunt for the Next button. Fires once; the short
        // delay lets both cards show their "Granted" state first.
        if microphoneGranted, accessibilityGranted, !didAutoAdvance {
            didAutoAdvance = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                onContinue()
            }
        }
    }

    private func requestMicrophonePermission() {
        guard !isRequestingMicrophone else { return }
        isRequestingMicrophone = true

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            isRequestingMicrophone = false
            microphoneGranted = true

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.isRequestingMicrophone = false
                    self.microphoneGranted = granted
                    if granted {
                        bringOnboardingWindowToFront()
                    } else {
                        openSystemSettings(anchor: "Privacy_Microphone")
                    }
                }
            }

        case .denied, .restricted:
            isRequestingMicrophone = false
            microphoneGranted = false
            openSystemSettings(anchor: "Privacy_Microphone")

        @unknown default:
            isRequestingMicrophone = false
            microphoneGranted = false
            openSystemSettings(anchor: "Privacy_Microphone")
        }
    }

    private func requestAccessibilityPermission() {
        guard !isRequestingAccessibility else { return }
        isRequestingAccessibility = true

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        // Do NOT pull the onboarding window back to the front here: the system
        // Accessibility prompt is non-modal and would end up hidden behind
        // onboarding (and the user re-clicking "Allow" feels like a double
        // prompt). If macOS no longer shows the prompt, open the exact Privacy
        // pane so the Allow click still gives the user a visible next step.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isRequestingAccessibility = false
            self.refreshPermissionStatus()
            if !self.accessibilityGranted {
                openSystemSettings(anchor: "Privacy_Accessibility")
            }
        }
    }
}

// MARK: - Screen Recording Step

struct ScreenRecordingStepView: View {
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var screenRecordingGranted = false
    @State private var isRequesting = false

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        OnboardingSplitFrame {
            VStack(alignment: .leading, spacing: 16) {
                Spacer(minLength: 0)

                Text("Meeting audio capture")
                    .font(OnboardingStyle.title)
                    .foregroundColor(OnboardingStyle.titleColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text("Allow Screen Recording only if you want Diduny to capture audio from Zoom, Meet, Teams, and similar apps.")
                    .font(OnboardingStyle.subtitle)
                    .foregroundColor(OnboardingStyle.titleColor.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Diduny uses this permission only to access meeting audio. It is not required for normal microphone dictation.")
                    .font(OnboardingStyle.body)
                    .foregroundColor(OnboardingStyle.titleColor.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                if screenRecordingGranted {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(OnboardingStyle.brandBlueDark)
                            Text("Permission granted. Restart Diduny once you've finished onboarding to enable meeting recording.")
                                .font(OnboardingStyle.body)
                                .foregroundColor(OnboardingStyle.titleColor.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                    OnboardingMainButton(title: "Next", action: onContinue)
                        .padding(.top, 6)
                } else {
                    OnboardingMainButton(
                        title: isRequesting ? "Requesting..." : "Allow Screen Recording",
                        disabled: isRequesting,
                        action: requestScreenRecordingPermission
                    )
                    .padding(.top, 8)
                }

                Spacer(minLength: 0)

                HStack(spacing: 24) {
                    OnboardingTextAction(title: "Back", icon: "arrow.uturn.left", action: onBack)
                    OnboardingTextAction(title: "Skip", action: onSkip)
                }
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        } right: {
            VStack(spacing: 12) {
                PermissionCardView(
                    number: 1,
                    title: "Allow Diduny to capture meeting audio.",
                    description: "macOS requires Screen Recording permission to access system audio streams from meeting apps.",
                    granted: screenRecordingGranted,
                    isRequesting: isRequesting,
                    onAllow: requestScreenRecordingPermission,
                    onOpenSettings: { openSystemSettings(anchor: "Privacy_ScreenCapture") }
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("When this is used")
                        .font(OnboardingStyle.cardTitle)
                        .foregroundColor(OnboardingStyle.titleColor)

                    Text("Only during Meeting recording mode.")
                        .font(OnboardingStyle.cardBody)
                        .foregroundColor(OnboardingStyle.titleColor.opacity(0.85))

                    Text("Not used for standard dictation.")
                        .font(OnboardingStyle.cardBody)
                        .foregroundColor(OnboardingStyle.titleColor.opacity(0.85))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .onAppear {
            Task { await refreshStatus() }
        }
        .onReceive(refreshTimer) { _ in
            Task { await refreshStatus() }
        }
    }

    private func refreshStatus() async {
        // Passive TCC read — does NOT trigger SCShareableContent (which would
        // cache a stale "denied" result inside the running process forever).
        let granted = PermissionManager.shared.checkScreenRecordingPermissionPassive()
        await MainActor.run {
            screenRecordingGranted = granted
        }
    }

    private func requestScreenRecordingPermission() {
        guard !isRequesting else { return }
        isRequesting = true

        Task {
            // Request only the native macOS TCC prompt here. Do not call
            // ensureScreenRecordingPermission(), because its fallback alert
            // duplicates the system "Open System Settings" prompt.
            _ = await PermissionManager.shared.requestScreenRecordingPermission()
            // The boolean returned above is unreliable inside the running
            // process due to SCShareableContent's cached state. The passive
            // refresh path is the source of truth — it polls TCC directly.
            await MainActor.run {
                isRequesting = false
            }
            await refreshStatus()
        }
    }
}

// MARK: - System settings / window helpers

private func openSystemSettings(anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
        return
    }
    NSWorkspace.shared.open(url)
}

private func bringOnboardingWindowToFront() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "diduny.onboarding" }) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return
    }
    for window in NSApp.windows where window.title == "Welcome to Diduny" || window.title == "Permissions Check" {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        break
    }
}

// MARK: - Shortcut Step

struct ShortcutStepView: View {
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var selectedKey: PushToTalkKey = .rightShift
    @State private var selectedMode: ShortcutMode = .pushToTalk

    private let availableKeys: [PushToTalkKey] = [
        .leftShift, .rightShift,
        .leftCommand, .rightCommand,
        .leftOption, .rightOption,
        .leftControl, .rightControl,
    ]
    private let keyGridColumns = Array(repeating: GridItem(.flexible(minimum: 90), spacing: 10), count: 4)

    enum ShortcutMode: String {
        case pushToTalk
        case handsFree

        var title: String {
            switch self {
            case .pushToTalk: return "Push-to-talk (Recommended)"
            case .handsFree: return "Hands-free (Toggle)"
            }
        }

        var subtitle: String {
            switch self {
            case .pushToTalk:
                return "Hold the key while speaking. Release to insert text."
            case .handsFree:
                return "Tap the key several times to start and stop recording. You can adjust the tap count later in Settings."
            }
        }
    }

    var body: some View {
        OnboardingWindowFrame {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Spacer(minLength: 0)

                    Text("Hold the keyboard shortcut")
                        .font(OnboardingStyle.title)
                        .foregroundColor(OnboardingStyle.titleColor)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    Text("Choose a default key and mode.")
                        .font(OnboardingStyle.subtitle)
                        .foregroundColor(OnboardingStyle.titleColor.opacity(0.92))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default key")
                            .font(OnboardingStyle.label)
                            .foregroundColor(OnboardingStyle.titleColor.opacity(0.85))

                        LazyVGrid(columns: keyGridColumns, alignment: .leading, spacing: 10) {
                            ForEach(availableKeys, id: \.self) { key in
                                ShortcutKeyChip(key: key, isSelected: selectedKey == key) {
                                    selectedKey = key
                                }
                            }
                        }
                    }
                    .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Would you like Hands-free mode?")
                            .font(OnboardingStyle.label)
                            .foregroundColor(OnboardingStyle.titleColor.opacity(0.85))

                        ShortcutModeOption(
                            title: ShortcutMode.pushToTalk.title,
                            subtitle: ShortcutMode.pushToTalk.subtitle,
                            isSelected: selectedMode == .pushToTalk
                        ) {
                            selectedMode = .pushToTalk
                        }

                        ShortcutModeOption(
                            title: ShortcutMode.handsFree.title,
                            subtitle: ShortcutMode.handsFree.subtitle,
                            isSelected: selectedMode == .handsFree
                        ) {
                            selectedMode = .handsFree
                        }
                    }

                    OnboardingMainButton(title: "Next") {
                        saveSettings()
                        onContinue()
                    }
                    .padding(.top, 8)

                    Spacer(minLength: 0)

                    HStack(spacing: 24) {
                        OnboardingTextAction(title: "Back", icon: "arrow.uturn.left", action: onBack)
                        OnboardingTextAction(title: "Skip", action: onSkip)
                    }
                    .padding(.bottom, 10)
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
            }
        }
        .onAppear {
            selectedKey = SettingsStorage.shared.pushToTalkKey == .none ? .rightShift : SettingsStorage.shared.pushToTalkKey
            selectedMode = SettingsStorage.shared.handsFreeModeEnabled ? .handsFree : .pushToTalk
        }
    }

    private func saveSettings() {
        SettingsStorage.shared.pushToTalkKey = selectedKey
        SettingsStorage.shared.handsFreeModeEnabled = selectedMode == .handsFree
        if selectedMode == .handsFree {
            SettingsStorage.shared.pushToTalkToggleTapCount = 3
        }
        NotificationCenter.default.post(name: .pushToTalkKeyChanged, object: selectedKey)
    }
}

private struct ShortcutKeyChip: View {
    let key: PushToTalkKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(key.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isSelected ? .white : OnboardingStyle.titleColor)
                Text(key.displayName.replacingOccurrences(of: "Right ", with: ""))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? .white.opacity(0.95) : OnboardingStyle.titleColor.opacity(0.8))
            }
            .frame(width: 90, height: 56)
            .background(isSelected ? OnboardingStyle.brandBlueDark : Color.white.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? OnboardingStyle.brandBlueDark : OnboardingStyle.titleColor.opacity(0.22), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ShortcutModeOption: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? OnboardingStyle.brandBlueDark : OnboardingStyle.titleColor.opacity(0.4))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(OnboardingStyle.titleColor)

                    Text(subtitle)
                        .font(OnboardingStyle.cardBody)
                        .foregroundColor(OnboardingStyle.titleColor.opacity(0.76))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? OnboardingStyle.brandBlueDark.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Complete Step

struct CompleteStepView: View {
    let onFinish: () -> Void

    @State private var showConfetti = false

    private var privacyCopy: String {
        switch SettingsStorage.shared.transcriptionProvider {
        case .local:
            return "All audio is processed on this Mac. Nothing is sent to external servers."
        case .cloud:
            return "Audio is sent to Diduny's proxy server and then to Soniox EU for transcription. No audio is stored after transcription completes. Your email is stored securely in the macOS Keychain."
        }
    }

    var body: some View {
        OnboardingWindowFrame {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    Spacer()

                    // Success icon (reduced from 100/50 to 64/32)
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.1))
                            .frame(width: 64, height: 64)

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.green)
                    }
                    .scaleEffect(showConfetti ? 1 : 0.5)
                    .opacity(showConfetti ? 1 : 0)

                    VStack(spacing: 8) {
                        Text("You're all set!")
                            .font(OnboardingStyle.title)

                        Text("Start transcribing with your shortcut key\nor use the menu bar.")
                            .font(OnboardingStyle.subtitle)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    // Quick tips
                    VStack(alignment: .leading, spacing: 10) {
                        TipRow(icon: "keyboard", text: "Use hold-to-record or configure multi-tap toggle mode")
                        TipRow(icon: "menubar.rectangle", text: "Click the menu bar icon for more options")
                        TipRow(icon: "gearshape", text: "Access settings anytime from the menu")
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                    // Privacy block — accurate per transcription provider
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Your audio & privacy", systemImage: "lock.shield.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(OnboardingStyle.titleColor)

                        Text(privacyCopy)
                            .font(OnboardingStyle.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: 420, alignment: .leading)
                    .background(Color.green.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.green.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.top, 6)

                    Spacer()

                    OnboardingMainButton(title: "Start Using Diduny") {
                        onFinish()
                    }
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showConfetti = true
            }
        }
    }
}

// MARK: - TipRow

struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 20)

            Text(text)
                .font(OnboardingStyle.tip)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingContainerView(onComplete: {})
        .frame(width: 820, height: 600)
}
