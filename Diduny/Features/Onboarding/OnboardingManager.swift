import Foundation
import SwiftUI

// MARK: - Onboarding Step

enum OnboardingStep: Int, Codable, CaseIterable {
    case welcome = 0
    case microphonePermission = 1
    case accessibilityPermission = 2
    case screenRecordingPermission = 3
    case shortcutSetup = 4
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

// MARK: - Onboarding Manager

@Observable
final class OnboardingManager {
    static let shared = OnboardingManager()

    private let hasCompletedOnboardingKey = "onboarding.completed"
    private let onboardingVersionKey = "onboarding.version"
    private let currentStepKey = "onboarding.currentStep"
    private let currentOnboardingVersion = 1

    // Step completion tracking
    private let stepCompletedPrefix = "onboarding.step."

    /// Force show onboarding even if completed (for settings)
    var forceShowOnboarding = false

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

    /// Check if onboarding should be shown
    var shouldShowOnboarding: Bool {
        // Always show if forced from settings
        if forceShowOnboarding {
            return true
        }

        // Skip if already completed
        if hasCompletedOnboarding {
            return false
        }

        // Show onboarding for new users
        return true
    }

    private init() {}

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

        // Clear all step completion flags
        for step in OnboardingStep.allCases {
            UserDefaults.standard.removeObject(forKey: stepCompletedPrefix + "\(step.rawValue)")
        }

        forceShowOnboarding = false
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

    func showOnboarding(completion: @escaping () -> Void) {
        if let window {
            // Window already exists, bring to front
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingContainerView(
            onComplete: {
                OnboardingManager.shared.hasCompletedOnboarding = true
                OnboardingManager.shared.forceShowOnboarding = false
                self.closeOnboarding()
                completion()
            }
        )

        let hostingView = NSHostingView(rootView: AnyView(onboardingView))
        self.hostingView = hostingView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Welcome to Diduny"
        window.contentView = hostingView
        window.identifier = NSUserInterfaceItemIdentifier("diduny.onboarding")
        window.center()
        window.minSize = NSSize(width: 1080, height: 700)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false

        self.windowDelegate = WindowDelegate(onClose: {
            // If user closes window without completing
            OnboardingManager.shared.forceShowOnboarding = false
            self.window = nil
            self.hostingView = nil
            self.windowDelegate = nil
            completion()
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
