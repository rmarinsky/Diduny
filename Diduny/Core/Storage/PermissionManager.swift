import AppKit
import ApplicationServices
import AVFAudio
import CoreGraphics
import Foundation

/// Manages all permission requests for the app
@MainActor
final class PermissionManager {
    static let shared = PermissionManager()

    // MARK: - Permission Status

    struct PermissionStatus: Sendable {
        var microphone: Bool = false
        var screenRecording: Bool = false
        var accessibility: Bool = false

        var allGranted: Bool {
            microphone && accessibility
        }

        var allCriticalGranted: Bool {
            microphone && accessibility
        }
    }

    private(set) var status = PermissionStatus()

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshStatus()
            }
        }

        Task { @MainActor in
            await self.refreshStatus()
        }
    }

    // MARK: - Individual Permission Requests (Async)

    func requestMicrophonePermission() async -> Bool {
        let recordPermission = AVAudioApplication.shared.recordPermission

        switch recordPermission {
        case .granted:
            NSLog("[Diduny] Microphone permission already granted")
            return true

        case .undetermined:
            NSLog("[Diduny] Microphone permission not determined, requesting...")
            let granted = await AVAudioApplication.requestRecordPermission()
            NSLog("[Diduny] Microphone permission request result: %@", granted ? "true" : "false")
            return granted

        case .denied:
            NSLog("[Diduny] Microphone permission denied")
            return false

        @unknown default:
            return false
        }
    }

    /// Check if microphone permission needs to be requested (not yet determined)
    func checkMicrophonePermissionStatus() -> AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    /// Request microphone permission - shows system dialog if not determined,
    /// or opens System Settings if denied
    func ensureMicrophonePermission(context: PermissionRequestContext = .general) async -> Bool {
        let recordPermission = AVAudioApplication.shared.recordPermission

        switch recordPermission {
        case .granted:
            return true

        case .undetermined:
            guard showPermissionGate(for: .microphone, mode: .request, context: context) else {
                return false
            }
            NSLog("[Diduny] Requesting microphone permission...")
            let granted = await AVAudioApplication.requestRecordPermission()
            await refreshStatus()
            if !granted {
                showSettingsGate(for: .microphone, context: context)
            }
            return granted

        case .denied:
            NSLog("[Diduny] Microphone permission denied, prompting user to open Settings")
            showSettingsGate(for: .microphone, context: context)
            return false

        @unknown default:
            return false
        }
    }

    func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func checkScreenRecordingPermission() async -> Bool {
        let granted = await SystemAudioCaptureService.checkPermission()
        status.screenRecording = granted
        return granted
    }

    /// Truly passive screen-recording check. Does NOT trigger the system permission dialog
    /// even when status is undetermined — uses CGPreflightScreenCaptureAccess(), which
    /// merely inspects the TCC database. Use this from the permission-gate startup logic
    /// so we don't surface the Screen Recording prompt before the user reaches that step.
    nonisolated func checkScreenRecordingPermissionPassive() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request screen recording permission - this triggers the system permission dialog
    /// by attempting to access SCShareableContent
    func requestScreenRecordingPermission() async -> Bool {
        // Skip if already granted
        if status.screenRecording || checkScreenRecordingPermissionPassive() {
            NSLog("[Diduny] Screen recording permission already granted")
            status.screenRecording = true
            return true
        }

        NSLog("[Diduny] Requesting screen recording permission...")

        // Calling SCShareableContent.excludingDesktopWindows triggers the permission dialog
        // if permission hasn't been determined yet
        let granted = await SystemAudioCaptureService.requestPermission()

        // Update cached status
        status.screenRecording = granted

        if granted {
            NSLog("[Diduny] Screen recording permission granted")
        } else {
            NSLog("[Diduny] Screen recording permission not granted")
        }

        return granted
    }

    /// Ensure screen recording permission. Shows a Diduny-owned explanation first,
    /// then triggers macOS' Screen Recording access flow only if the user agrees.
    func ensureScreenRecordingPermission(context: PermissionRequestContext = .general) async -> Bool {
        if checkScreenRecordingPermissionPassive() {
            status.screenRecording = true
            return true
        }

        guard showPermissionGate(for: .screenRecording, mode: .request, context: context) else {
            return false
        }

        let granted = await requestScreenRecordingPermission()

        if !granted {
            NSLog("[Diduny] Screen recording permission not granted, opening System Settings")
            showSettingsGate(for: .screenRecording, context: context)
        }

        return granted
    }

    func ensureAccessibilityPermission(context: PermissionRequestContext = .general) async -> Bool {
        if checkAccessibilityPermission() {
            status.accessibility = true
            return true
        }

        guard showPermissionGate(for: .accessibility, mode: .request, context: context) else {
            return false
        }

        requestAccessibilityPermission()
        try? await Task.sleep(for: .seconds(1))
        await refreshStatus()

        if status.accessibility {
            return true
        }

        showSettingsGate(for: .accessibility, context: context)
        return checkAccessibilityPermission()
    }

    func ensurePermission(_ type: PermissionType, context: PermissionRequestContext = .general) async -> Bool {
        switch type {
        case .microphone:
            return await ensureMicrophonePermission(context: context)
        case .accessibility:
            return await ensureAccessibilityPermission(context: context)
        case .screenRecording:
            return await ensureScreenRecordingPermission(context: context)
        }
    }

    // MARK: - Helper Methods

    /// Refresh permission status passively - only checks current status without triggering any dialogs
    /// Note: Screen recording cannot be checked passively, so we keep the last known state
    func refreshStatus() async {
        // Check microphone status passively (no dialog)
        status.microphone = AVAudioApplication.shared.recordPermission == .granted

        // Check accessibility passively (this is always passive)
        status.accessibility = checkAccessibilityPermission()

        // Screen recording: cannot check passively without triggering dialog
        // Keep the last known state - don't update status.screenRecording here
    }

    /// Show individual permission alert
    func showPermissionAlert(for type: PermissionType) {
        Task {
            let context: PermissionRequestContext
            switch type {
            case .accessibility:
                context = .autoPaste
            case .microphone, .screenRecording:
                context = .general
            }
            _ = await ensurePermission(type, context: context)
        }
    }

    @discardableResult
    private func showPermissionGate(
        for type: PermissionType,
        mode: PermissionPromptMode,
        context: PermissionRequestContext
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(type.displayName) Access Needed"
        alert.informativeText = type.explanation(for: context, mode: mode)
        alert.alertStyle = .informational
        if let icon = NSImage(systemSymbolName: type.symbolName, accessibilityDescription: type.displayName) {
            alert.icon = icon
        }
        alert.addButton(withTitle: mode.primaryButtonTitle)
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showSettingsGate(for type: PermissionType, context: PermissionRequestContext) {
        if showPermissionGate(for: type, mode: .settings, context: context) {
            openSystemSettingsForPermission(type)
        }
    }

    private func openSystemSettingsForPermission(_ type: PermissionType) {
        var urlString: String?

        switch type {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }

        if let urlString, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Permission Types

enum PermissionType {
    case microphone
    case accessibility
    case screenRecording

    var displayName: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    var symbolName: String {
        switch self {
        case .microphone: "mic.fill"
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.on.rectangle"
        }
    }

    var settingsPath: String {
        switch self {
        case .microphone: "System Settings > Privacy & Security > Microphone"
        case .accessibility: "System Settings > Privacy & Security > Accessibility"
        case .screenRecording: "System Settings > Privacy & Security > Screen & System Audio Recording"
        }
    }

    func explanation(for context: PermissionRequestContext, mode: PermissionPromptMode) -> String {
        let action = context.blockedAction(for: self)
        switch mode {
        case .request:
            return """
                Diduny can't \(action) because \(displayName) access is missing.

                \(reason)

                Do you want to grant access now?
                """
        case .settings:
            return """
                Diduny still can't \(action) because \(displayName) access is not enabled.

                Enable it in \(settingsPath), then return to Diduny.
                """
        }
    }

    private var reason: String {
        switch self {
        case .microphone:
            "This lets Diduny capture your voice for dictation and translation."
        case .accessibility:
            "This lets Diduny paste the finished text into the app you were using. It does not read or control apps unless you trigger a Diduny action."
        case .screenRecording:
            "macOS uses this permission for system audio capture in calls and meetings. Diduny records audio for transcription, not your screen video."
        }
    }
}

enum PermissionRequestContext: Sendable {
    case dictation
    case translation
    case meetingRecording
    case meetingTranslation
    case autoPaste
    case settings
    case general

    func blockedAction(for type: PermissionType) -> String {
        switch self {
        case .dictation:
            return "start dictation"
        case .translation:
            return "start voice translation"
        case .meetingRecording:
            return "record meeting audio"
        case .meetingTranslation:
            return "translate meeting audio"
        case .autoPaste:
            return "paste the transcript automatically"
        case .settings:
            return "enable this permission"
        case .general:
            switch type {
            case .microphone:
                return "record audio"
            case .accessibility:
                return "control paste actions"
            case .screenRecording:
                return "capture meeting audio"
            }
        }
    }
}

enum PermissionPromptMode {
    case request
    case settings

    var primaryButtonTitle: String {
        switch self {
        case .request: "Grant Access"
        case .settings: "Open System Settings"
        }
    }
}
