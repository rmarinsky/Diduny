import AVFoundation
import ApplicationServices
import SwiftUI

private enum OnboardingStyle {
    static let brandBlue = Color(red: 0.15, green: 0.51, blue: 0.95)
    static let brandBlueDark = Color(red: 0.09, green: 0.41, blue: 0.84)
    static let panelBlue = Color(red: 0.80, green: 0.88, blue: 0.98)
    static let titleColor = Color(red: 0.16, green: 0.24, blue: 0.50)
}

/// Main container that manages onboarding flow and step navigation
struct OnboardingContainerView: View {
    let onComplete: () -> Void

    @State private var currentStep: OnboardingStep = OnboardingManager.shared.currentStep

    var body: some View {
        ZStack {
            OnboardingBackgroundView()

            Group {
                switch currentStep {
                case .welcome:
                    WelcomeStepView(onContinue: { navigate(to: .microphonePermission) })

                case .microphonePermission, .accessibilityPermission:
                    SetupComputerStepView(
                        onBack: { navigate(to: .welcome, markCurrentAsComplete: false) },
                        onContinue: { navigate(to: .screenRecordingPermission) },
                        onSkip: { navigate(to: .screenRecordingPermission) }
                    )

                case .screenRecordingPermission:
                    ScreenRecordingStepView(
                        onBack: { navigate(to: .microphonePermission, markCurrentAsComplete: false) },
                        onContinue: { navigate(to: .shortcutSetup) },
                        onSkip: { navigate(to: .shortcutSetup) }
                    )

                case .shortcutSetup:
                    ShortcutStepView(
                        onBack: { navigate(to: .screenRecordingPermission, markCurrentAsComplete: false) },
                        onContinue: { navigate(to: .complete) },
                        onSkip: { navigate(to: .complete) }
                    )

                case .apiSetup:
                    // Legacy step — skip directly to complete
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
            .padding(14)
        }
        .onAppear(perform: restoreCurrentStep)
    }

    private func restoreCurrentStep() {
        let savedStep = OnboardingManager.shared.currentStep
        // The .accessibilityPermission step is handled together with .microphonePermission
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
        // Always persist the actual destination step
        OnboardingManager.shared.currentStep = step

        withAnimation(.easeInOut(duration: 0.28)) {
            currentStep = step
        }
    }
}

// MARK: - Shared Layout

private struct OnboardingWindowFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeaderBar()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 20, y: 10)
    }
}

private struct OnboardingHeaderBar: View {
    var body: some View {
        ZStack {
            OnboardingStyle.brandBlue
            Text("Diduny app")
                .font(.system(size: 20, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.white.opacity(0.95))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(height: 58)
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
        OnboardingWindowFrame {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    left
                        .frame(width: proxy.size.width * 0.50, height: proxy.size.height, alignment: .topLeading)
                        .background(Color.white)

                    right
                        .frame(width: proxy.size.width * 0.50, height: proxy.size.height, alignment: .topLeading)
                        .background(OnboardingStyle.panelBlue)
                }
            }
        }
    }
}

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
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(disabled ? OnboardingStyle.brandBlue.opacity(0.45) : OnboardingStyle.brandBlueDark)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            .font(.system(size: 18, weight: .semibold))
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
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(disabled ? OnboardingStyle.brandBlue.opacity(0.45) : OnboardingStyle.brandBlueDark)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(OnboardingStyle.brandBlueDark)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.white.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(OnboardingStyle.brandBlueDark.opacity(0.65), lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionCardView: View {
    let title: String
    let description: String
    let granted: Bool
    let isRequesting: Bool
    let onAllow: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(OnboardingStyle.titleColor)

                Text(description)
                    .font(.system(size: 18))
                    .foregroundColor(OnboardingStyle.titleColor.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if granted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                    Text("Granted")
                }
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.green)
            } else {
                HStack(spacing: 12) {
                    PermissionActionButton(
                        title: isRequesting ? "Requesting..." : "Allow",
                        disabled: isRequesting,
                        action: onAllow
                    )
                    PermissionOutlineButton(title: "Open settings", action: onOpenSettings)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Welcome Step

struct WelcomeStepView: View {
    let onContinue: () -> Void

    @State private var showButton = false

    var body: some View {
        OnboardingWindowFrame {
            ZStack {
                LinearGradient(
                    colors: [OnboardingStyle.brandBlue, OnboardingStyle.brandBlueDark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: 34) {
                    Spacer()

                    Text("Any language. Any voice.\nInstantly.")
                        .font(.system(size: 88, weight: .bold))
                        .foregroundColor(.white.opacity(0.96))
                        .multilineTextAlignment(.center)
                        .lineSpacing(12)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 24)

                    if showButton {
                        Button(action: onContinue) {
                            Text("Start using Diduny")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(OnboardingStyle.brandBlueDark)
                                .padding(.horizontal, 42)
                                .padding(.vertical, 18)
                                .background(Color.white.opacity(0.94))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

// MARK: - Permissions Setup Step

struct SetupComputerStepView: View {
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var isRequestingMicrophone = false
    @State private var isRequestingAccessibility = false

    private let refreshTimer = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    var body: some View {
        OnboardingSplitFrame {
            VStack(alignment: .leading, spacing: 26) {
                Spacer(minLength: 0)

                Text("Set up your computer")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundColor(OnboardingStyle.titleColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text("Enable permissions to start using Diduny.")
                    .font(.system(size: 30))
                    .foregroundColor(OnboardingStyle.titleColor.opacity(0.92))

                OnboardingMainButton(title: "Next", disabled: !canContinue) {
                    onContinue()
                }
                .padding(.top, 8)

                Spacer(minLength: 0)

                HStack(spacing: 32) {
                    OnboardingTextAction(title: "Back", icon: "arrow.uturn.left", action: onBack)
                    OnboardingTextAction(title: "Skip", action: onSkip)
                }
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 46)
        } right: {
            VStack(spacing: 20) {
                PermissionCardView(
                    title: "Allow Diduny to insert spoken words.",
                    description: "This allows Diduny to insert transcribed words into text fields.",
                    granted: accessibilityGranted,
                    isRequesting: isRequestingAccessibility,
                    onAllow: requestAccessibilityPermission,
                    onOpenSettings: { openSystemSettings(anchor: "Privacy_Accessibility") }
                )

                PermissionCardView(
                    title: "Allow Diduny to use your microphone.",
                    description: "This allows Diduny to capture your speech for dictation and translation.",
                    granted: microphoneGranted,
                    isRequesting: isRequestingMicrophone,
                    onAllow: requestMicrophonePermission,
                    onOpenSettings: { openSystemSettings(anchor: "Privacy_Microphone") }
                )

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 54)
            .padding(.vertical, 44)
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
    }

    private func requestMicrophonePermission() {
        guard !isRequestingMicrophone else { return }
        isRequestingMicrophone = true
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.isRequestingMicrophone = false
                self.microphoneGranted = granted
                bringOnboardingWindowToFront()
            }
        }
    }

    private func requestAccessibilityPermission() {
        guard !isRequestingAccessibility else { return }
        isRequestingAccessibility = true

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.isRequestingAccessibility = false
            self.refreshPermissionStatus()
            bringOnboardingWindowToFront()
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
            VStack(alignment: .leading, spacing: 26) {
                Spacer(minLength: 0)

                Text("Meeting audio capture")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundColor(OnboardingStyle.titleColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text("Allow Screen Recording only if you want Diduny to capture audio from Zoom, Meet, Teams, and similar apps.")
                    .font(.system(size: 26))
                    .foregroundColor(OnboardingStyle.titleColor.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Diduny uses this permission only to access meeting audio. It is not required for normal microphone dictation.")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(OnboardingStyle.titleColor.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                if screenRecordingGranted {
                    OnboardingMainButton(title: "Next", action: onContinue)
                        .padding(.top, 8)
                } else {
                    OnboardingMainButton(
                        title: isRequesting ? "Requesting..." : "Allow Screen Recording",
                        disabled: isRequesting,
                        action: requestScreenRecordingPermission
                    )
                    .padding(.top, 8)
                }

                Spacer(minLength: 0)

                HStack(spacing: 32) {
                    OnboardingTextAction(title: "Back", icon: "arrow.uturn.left", action: onBack)
                    OnboardingTextAction(title: "Skip", action: onSkip)
                }
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 46)
        } right: {
            VStack(spacing: 20) {
                PermissionCardView(
                    title: "Allow Diduny to capture meeting audio.",
                    description: "macOS requires Screen Recording permission to access system audio streams from meeting apps.",
                    granted: screenRecordingGranted,
                    isRequesting: isRequesting,
                    onAllow: requestScreenRecordingPermission,
                    onOpenSettings: { openSystemSettings(anchor: "Privacy_ScreenCapture") }
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("When this is used")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(OnboardingStyle.titleColor)

                    Text("Only during Meeting recording mode.")
                        .font(.system(size: 18))
                        .foregroundColor(OnboardingStyle.titleColor.opacity(0.85))

                    Text("Not used for standard dictation.")
                        .font(.system(size: 18))
                        .foregroundColor(OnboardingStyle.titleColor.opacity(0.85))
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 54)
            .padding(.vertical, 44)
        }
        .onAppear {
            Task { await refreshStatus() }
        }
        .onReceive(refreshTimer) { _ in
            Task { await refreshStatus() }
        }
    }

    private func refreshStatus() async {
        let granted = await PermissionManager.shared.checkScreenRecordingPermission()
        await MainActor.run {
            screenRecordingGranted = granted
        }
    }

    private func requestScreenRecordingPermission() {
        guard !isRequesting else { return }
        isRequesting = true

        Task {
            let granted = await PermissionManager.shared.requestScreenRecordingPermission()
            await MainActor.run {
                isRequesting = false
                screenRecordingGranted = granted
                bringOnboardingWindowToFront()
            }
        }
    }
}

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

    for window in NSApp.windows where window.title == "Welcome to Diduny" {
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

    private let availableKeys: [PushToTalkKey] = [.rightShift, .rightCommand, .rightOption, .rightControl]

    enum ShortcutMode: String {
        case pushToTalk
        case handsFree

        var title: String {
            switch self {
            case .pushToTalk:
                return "Push-to-talk (Recommended)"
            case .handsFree:
                return "Hands-free (Double tap)"
            }
        }

        var subtitle: String {
            switch self {
            case .pushToTalk:
                return "Hold the key while speaking. Release to insert text."
            case .handsFree:
                return "Double-tap to start recording, double-tap again to stop."
            }
        }
    }

    var body: some View {
        OnboardingWindowFrame {
            VStack(alignment: .leading, spacing: 22) {
                Spacer(minLength: 0)

                Text("Hold the keyboard shortcut")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundColor(OnboardingStyle.titleColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text("Choose a default key and mode.")
                    .font(.system(size: 30))
                    .foregroundColor(OnboardingStyle.titleColor.opacity(0.92))

                VStack(alignment: .leading, spacing: 14) {
                    Text("Default key")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(OnboardingStyle.titleColor.opacity(0.85))

                    HStack(spacing: 10) {
                        ForEach(availableKeys, id: \.self) { key in
                            ShortcutKeyChip(key: key, isSelected: selectedKey == key) {
                                selectedKey = key
                            }
                        }
                    }
                }
                .padding(.top, 6)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Would you like Hands-free mode?")
                        .font(.system(size: 18, weight: .semibold))
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

                HStack(spacing: 32) {
                    OnboardingTextAction(title: "Back", icon: "arrow.uturn.left", action: onBack)
                    OnboardingTextAction(title: "Skip", action: onSkip)
                }
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 46)
        }
        .onAppear {
            selectedKey = SettingsStorage.shared.pushToTalkKey == .none ? .rightShift : SettingsStorage.shared.pushToTalkKey
            selectedMode = SettingsStorage.shared.handsFreeModeEnabled ? .handsFree : .pushToTalk
        }
    }

    private func saveSettings() {
        SettingsStorage.shared.pushToTalkKey = selectedKey
        SettingsStorage.shared.handsFreeModeEnabled = selectedMode == .handsFree
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
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(isSelected ? .white : OnboardingStyle.titleColor)
                Text(key.displayName.replacingOccurrences(of: "Right ", with: ""))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? .white.opacity(0.95) : OnboardingStyle.titleColor.opacity(0.8))
            }
            .frame(width: 90, height: 62)
            .background(isSelected ? OnboardingStyle.brandBlueDark : Color.white.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? OnboardingStyle.brandBlueDark : OnboardingStyle.titleColor.opacity(0.4))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(OnboardingStyle.titleColor)

                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundColor(OnboardingStyle.titleColor.opacity(0.76))
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
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

            // Privacy & security info
            VStack(alignment: .leading, spacing: 8) {
                Label("Your data stays on your device", systemImage: "lock.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(OnboardingStyle.titleColor)

                Text("All your data \u{2014} recordings, transcriptions, and usage stats \u{2014} is stored only on your Mac and never sent to our servers. We only use your email for authorization. Credentials are stored securely in the macOS Keychain.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: 420, alignment: .leading)
            .background(Color.green.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.green.opacity(0.2), lineWidth: 1)
            )
            .padding(.top, 8)

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
        .frame(width: 1320, height: 820)
}
