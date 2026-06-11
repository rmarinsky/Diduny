import AVFoundation
import ApplicationServices
import Foundation
import SwiftUI

// MARK: - Onboarding Step

enum OnboardingStep: Int, Codable, CaseIterable {
    case welcome = 0
    case microphonePermission = 1
    case accessibilityPermission = 2
    case screenRecordingPermission = 3
    case shortcutSetup = 4
    // Deprecated — see docs/decisions/0008-onboarding-step-enum-stability.md
    // DO NOT remove: rawValue 5 may be persisted in UserDefaults on existing installs.
    case apiSetup = 5
    case complete = 6

    var displayName: String {
        switch self {
        case .welcome: return "Welcome"
        case .microphonePermission: return "Microphone"
        case .accessibilityPermission: return "Accessibility"
        case .screenRecordingPermission: return "Screen Recording"
        case .shortcutSetup: return "Shortcut Setup"
        case .apiSetup: return "API Setup"
        case .complete: return "Complete"
        }
    }

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
    }
}

// MARK: - Startup Action

enum StartupAction {
    case skipOnboarding
    case showFullTour(jumpToFirstMissing: OnboardingStep?)
    case showMiniFlow(steps: [OnboardingStep])
}

// MARK: - Onboarding Manager

@Observable
final class OnboardingManager {
    static let shared = OnboardingManager()

    private let hasCompletedOnboardingKey = "onboarding.completed"
    private let onboardingVersionKey = "onboarding.version"
    private let currentStepKey = "onboarding.currentStep"
    private let firstLaunchTimestampKey = "onboarding.firstLaunchTimestamp"
    private let currentOnboardingVersion = 1

    // Step completion tracking
    private let stepCompletedPrefix = "onboarding.step."

    /// Force show onboarding even if completed (for settings)
    var forceShowOnboarding = false

    /// Set by computeStartupAction — signals the mini-flow step sequence to show
    var miniFlowSteps: [OnboardingStep]? = nil

    /// Current step to resume from
    var currentStep: OnboardingStep {
        get {
            let rawValue = UserDefaults.standard.integer(forKey: currentStepKey)
            return OnboardingStep(rawValue: rawValue) ?? .welcome
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: currentStepKey)
        }
    }

    var hasCompletedOnboarding: Bool {
        get {
            let completedVersion = UserDefaults.standard.integer(forKey: onboardingVersionKey)
            let hasCompleted = UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey)
            return hasCompleted && completedVersion >= currentOnboardingVersion
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hasCompletedOnboardingKey)
            if newValue {
                UserDefaults.standard.set(currentOnboardingVersion, forKey: onboardingVersionKey)
                currentStep = .complete
            }
        }
    }

    /// Check if this is the first launch ever
    var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey)
    }

    /// Check if onboarding should be shown (legacy sync path — settings / force-show only)
    var shouldShowOnboarding: Bool {
        if forceShowOnboarding { return true }
        if hasCompletedOnboarding { return false }
        return true
    }

    private init() {
        writeFirstLaunchTimestampIfNeeded()
    }

    // MARK: - First-launch timestamp (legacy-user detection signal)

    private func writeFirstLaunchTimestampIfNeeded() {
        guard UserDefaults.standard.object(forKey: firstLaunchTimestampKey) == nil else { return }
        UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate,
                                  forKey: firstLaunchTimestampKey)
    }

    // MARK: - Permission-gate startup decision tree

    /// Async: evaluates live permission state and returns the correct startup action.
    func computeStartupAction() async -> StartupAction {
        if forceShowOnboarding {
            return .showFullTour(jumpToFirstMissing: nil)
        }

        // Live permission check — must be PASSIVE so we don't surface system prompts
        // for permissions whose step the user hasn't reached yet.
        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessGranted = AXIsProcessTrusted()
        let screenGranted = PermissionManager.shared.checkScreenRecordingPermissionPassive()
        let userDeclinedScreen = SettingsStorage.shared.userDeclinedScreenRecording

        // Build ordered missing-steps list.
        // Microphone + Accessibility share one combined screen
        // (SetupComputerStepView), so they collapse into a single step —
        // otherwise the mini-flow renders the identical screen twice.
        var missingSteps: [OnboardingStep] = []
        if !micGranted || !accessGranted { missingSteps.append(.microphonePermission) }
        if !screenGranted && !userDeclinedScreen { missingSteps.append(.screenRecordingPermission) }

        // All permissions satisfied — skip regardless of hasCompletedOnboarding
        if missingSteps.isEmpty { return .skipOnboarding }

        // Legacy-user detection
        let isLegacyUser = detectLegacyUser()

        if !hasCompletedOnboarding && !isLegacyUser {
            return .showFullTour(jumpToFirstMissing: missingSteps.first)
        } else {
            return .showMiniFlow(steps: missingSteps)
        }
    }

    private func detectLegacyUser() -> Bool {
        let hasFirstLaunchTimestamp = UserDefaults.standard.object(forKey: firstLaunchTimestampKey) != nil
        // Timestamp is written on first launch; if it's already present before computeStartupAction
        // runs (because init() ran first this session), the user is NOT a legacy user — they simply
        // haven't finished onboarding. The legacy case is: an update install where the old app never
        // wrote the timestamp, but a Supabase session is present.
        // NOTE: init() always writes the timestamp on first launch of this build. So for a legacy
        // user updating from a pre-onboarding build, the timestamp is written THIS launch. We
        // therefore check the session BEFORE the timestamp write would disambiguate — which means
        // we must rely solely on the session signal here.
        // ADR-0008 Decision 2 is the authoritative contract.
        if hasFirstLaunchTimestamp && !forceShowOnboarding {
            // Already launched with onboarding present — not a legacy user
            // UNLESS this is literally the first call this run AND the timestamp was
            // just written by init(). We can't distinguish those two; we fall back to
            // the session signal as the tie-breaker.
            let hasSession = AuthService.hasStoredSession
            if hasSession { return true }
        }
        // Timestamp absent (pre-onboarding build update): check session
        return AuthService.hasStoredSession
    }

    // MARK: - Step Management

    /// Mark a step as completed and move to next
    func completeStep(_ step: OnboardingStep) {
        UserDefaults.standard.set(true, forKey: stepCompletedPrefix + "\(step.rawValue)")

        // Move to next step
        if let next = step.next {
            currentStep = next
        }
    }

    /// Check if a specific step was completed
    func isStepCompleted(_ step: OnboardingStep) -> Bool {
        UserDefaults.standard.bool(forKey: stepCompletedPrefix + "\(step.rawValue)")
    }

    /// Skip to a specific step
    func skipToStep(_ step: OnboardingStep) {
        currentStep = step
    }

    // MARK: - Reset & Settings

    /// Reset onboarding (for testing)
    func reset() {
        UserDefaults.standard.removeObject(forKey: hasCompletedOnboardingKey)
        UserDefaults.standard.removeObject(forKey: onboardingVersionKey)
        UserDefaults.standard.removeObject(forKey: currentStepKey)
        UserDefaults.standard.removeObject(forKey: firstLaunchTimestampKey)

        // Clear all step completion flags
        for step in OnboardingStep.allCases {
            UserDefaults.standard.removeObject(forKey: stepCompletedPrefix + "\(step.rawValue)")
        }

        forceShowOnboarding = false
        miniFlowSteps = nil
        currentStep = .welcome
    }

    /// Show onboarding from settings - resumes from current step
    func showFromSettings() {
        forceShowOnboarding = true
        // Always restart from the beginning when opening from settings.
        if hasCompletedOnboarding || currentStep == .complete {
            currentStep = .welcome
        }
    }

    /// Set up default settings for new users
    func setupDefaultsForNewUser() {
        guard isFirstLaunch else { return }

        SettingsStorage.shared.pushToTalkKey = .rightShift
        SettingsStorage.shared.handsFreeModeEnabled = false
        SettingsStorage.shared.pushToTalkToggleTapCount = 3
        SettingsStorage.shared.translationPushToTalkToggleTapCount = 3
        SettingsStorage.shared.meetingHotkeyPressCount = 1
        SettingsStorage.shared.meetingTranslationHotkeyPressCount = 1
        SettingsStorage.shared.autoPaste = true
        SettingsStorage.shared.playSoundOnCompletion = true
    }
}

// MARK: - Onboarding Window Controller

final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private var windowDelegate: WindowDelegate?

    private init() {}

    func showOnboarding(miniFlow: [OnboardingStep]? = nil,
                        completion: @escaping () -> Void)
    {
        // Promote app to regular activation so the onboarding window appears
        // in the Dock and Cmd+Tab switcher. Diduny is LSUIElement (menu bar
        // app), which by default hides windows from the Dock — bad for a
        // first-run setup flow where the user needs to find the window.
        // Reverted to .accessory in closeOnboarding().
        NSApp.setActivationPolicy(.regular)

        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        OnboardingManager.shared.miniFlowSteps = miniFlow

        let isMiniFlow = miniFlow != nil
        let windowTitle = isMiniFlow ? "Permissions Check" : "Welcome to Diduny"

        let onboardingView = OnboardingContainerView(
            onComplete: {
                OnboardingManager.shared.hasCompletedOnboarding = true
                OnboardingManager.shared.forceShowOnboarding = false
                OnboardingManager.shared.miniFlowSteps = nil
                self.closeOnboarding()
                completion()
            }
        )

        let hostingView = NSHostingView(rootView: AnyView(onboardingView))
        self.hostingView = hostingView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = windowTitle
        window.contentView = hostingView
        window.identifier = NSUserInterfaceItemIdentifier("diduny.onboarding")
        window.center()
        window.minSize = NSSize(width: 680, height: 520)
        window.isReleasedWhenClosed = false
        // Native macOS titlebar — no custom overrides
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true

        self.windowDelegate = WindowDelegate(onClose: {
            // Close-via-X: save currentStep but do NOT mark hasCompletedOnboarding.
            // Next launch resumes from saved step.
            OnboardingManager.shared.forceShowOnboarding = false
            OnboardingManager.shared.miniFlowSteps = nil
            self.window = nil
            self.hostingView = nil
            self.windowDelegate = nil
            // Revert to menu-bar-only mode now that the onboarding window is gone.
            NSApp.setActivationPolicy(.accessory)
            // Do NOT call completion() here — that would trigger setupAfterOnboarding
            // prematurely while onboarding is unfinished.
        })
        window.delegate = self.windowDelegate

        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeOnboarding() {
        window?.delegate = nil
        window?.close()
        window = nil
        hostingView = nil
        windowDelegate = nil
        // Revert to menu-bar-only mode (LSUIElement behaviour) — no Dock icon
        // for normal app usage.
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Window Delegate

private final class WindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_: Notification) {
        onClose()
    }
}
