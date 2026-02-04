import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import os

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

    private init() {}

    // MARK: - Request All Permissions (Async)

    /// Request all permissions at app launch
    /// This will trigger system permission dialogs for microphone and screen recording
    func requestAllPermissions() async -> PermissionStatus {
        Log.permissions.info("Starting permission requests...")

        // Request permissions in parallel using async let
        // These methods will trigger the system permission dialogs if not yet determined
        async let microphoneGranted = requestMicrophonePermission()
        async let screenRecordingGranted = requestScreenRecordingPermission()

        // Accessibility is synchronous
        let accessibilityGranted = checkAccessibilityPermission()

        // Await all parallel requests
        status.microphone = await microphoneGranted
        status.screenRecording = await screenRecordingGranted
        status.accessibility = accessibilityGranted

        Log.permissions.info("All permissions checked")
        let statusMsg = "Status: Mic=\(status.microphone), Screen=\(status.screenRecording), " +
            "Accessibility=\(status.accessibility)"
        Log.permissions.info("\(statusMsg)")

        // Show permission prompt if needed for critical permissions (microphone and accessibility)
        if !status.allCriticalGranted {
            return await showPermissionPrompt()
        }

        // If screen recording is not granted, show a prompt for it separately
        if !status.screenRecording {
            Log.permissions.info("Screen recording not granted, showing optional permission prompt")
            await showScreenRecordingOptionalPrompt()
        }

        return status
    }

    /// Show an optional prompt for screen recording permission
    private func showScreenRecordingOptionalPrompt() async {
        let alert = NSAlert()
        alert.messageText = "Enable Meeting Recording?"
        alert.informativeText = """
            Diduny can record meeting audio (Zoom, Meet, Teams, etc.) for transcription.

            This requires Screen Recording permission.

            Would you like to enable this feature?
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Open System Settings for screen recording
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Individual Permission Requests (Async)

    func requestMicrophonePermission() async -> Bool {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        switch authStatus {
        case .authorized:
            Log.permissions.info("Microphone permission already granted")
            return true

        case .notDetermined:
            Log.permissions.info("Microphone permission not determined, requesting...")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.permissions.info("Microphone permission request result: \(granted)")
            return granted

        case .denied, .restricted:
            Log.permissions.warning("Microphone permission denied/restricted")
            return false

        @unknown default:
            return false
        }
    }

    /// Check if microphone permission needs to be requested (not yet determined)
    func checkMicrophonePermissionStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Request microphone permission - shows system dialog if not determined,
    /// or opens System Settings if denied
    func ensureMicrophonePermission() async -> Bool {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        switch authStatus {
        case .authorized:
            return true

        case .notDetermined:
            // Request permission - this will show the system dialog
            Log.permissions.info("Requesting microphone permission...")
            return await AVCaptureDevice.requestAccess(for: .audio)

        case .denied, .restricted:
            // Permission was denied - prompt user to open System Settings
            Log.permissions.info("Microphone permission denied, prompting user to open Settings")
            await MainActor.run {
                showPermissionAlert(for: .microphone)
            }
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
        guard #available(macOS 13.0, *) else {
            return false
        }
        return await SystemAudioCaptureService.checkPermission()
    }

    /// Request screen recording permission - this triggers the system permission dialog
    /// by attempting to access SCShareableContent
    func requestScreenRecordingPermission() async -> Bool {
        guard #available(macOS 13.0, *) else {
            Log.permissions.warning("Screen recording requires macOS 13.0+")
            return false
        }

        Log.permissions.info("Requesting screen recording permission...")

        // Calling SCShareableContent.excludingDesktopWindows triggers the permission dialog
        // if permission hasn't been determined yet
        let granted = await SystemAudioCaptureService.requestPermission()

        if granted {
            Log.permissions.info("Screen recording permission granted")
        } else {
            Log.permissions.warning("Screen recording permission not granted")
        }

        return granted
    }

    /// Ensure screen recording permission - request if not determined, or prompt to open Settings if denied
    func ensureScreenRecordingPermission() async -> Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }

        // First, try to get permission (this will trigger the dialog if not determined)
        let granted = await requestScreenRecordingPermission()

        if !granted {
            // If not granted, show alert to open System Settings
            Log.permissions.warning("Screen recording permission denied, prompting user to open Settings")
            await MainActor.run {
                showPermissionAlert(for: .screenRecording)
            }
        }

        return granted
    }

    // MARK: - Permission Prompt UI

    private func showPermissionPrompt() async -> PermissionStatus {
        let alert = NSAlert()
        alert.messageText = "Diduny Needs Permissions"
        alert.alertStyle = .informational

        var message = "To function properly, Diduny needs the following permissions:\n\n"

        if !status.microphone {
            message += "🎤 Microphone Access (Required)\n   • Record audio for transcription\n\n"
        }

        if !status.accessibility {
            message += "♿️ Accessibility Access (Required)\n   • Auto-paste transcribed text\n\n"
        }

        if !status.screenRecording {
            message += "🖥️ Screen Recording (Optional)\n   • Record meeting audio\n\n"
        }

        message += "Click 'Grant Permissions' to open System Settings and enable these permissions."

        alert.informativeText = message
        alert.addButton(withTitle: "Grant Permissions")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            return await openSystemSettings()
        }

        return status
    }

    private func openSystemSettings() async -> PermissionStatus {
        // Determine which settings to open based on what's missing
        var urlString: String?

        if !status.microphone {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        } else if !status.accessibility {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        } else if !status.screenRecording {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }

        if let urlString, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)

            // Wait for user to grant permissions
            try? await Task.sleep(for: .seconds(3))
            return await recheckPermissions()
        }

        return status
    }

    private func recheckPermissions() async -> PermissionStatus {
        Log.permissions.info("Rechecking permissions...")

        // Recheck all permissions in parallel
        async let microphoneGranted = requestMicrophonePermission()
        async let screenRecordingGranted = checkScreenRecordingPermission()

        status.microphone = await microphoneGranted
        status.screenRecording = await screenRecordingGranted
        status.accessibility = checkAccessibilityPermission()

        Log.permissions
            .info(
                "Recheck complete: Mic=\(self.status.microphone), Screen=\(self.status.screenRecording), Accessibility=\(self.status.accessibility)"
            )

        // If still missing critical permissions, offer to try again
        if !status.allCriticalGranted {
            return await showPermissionFollowUp()
        }

        return status
    }

    private func showPermissionFollowUp() async -> PermissionStatus {
        let alert = NSAlert()
        alert.messageText = "Permissions Still Required"
        alert.informativeText = """
            Diduny still needs some permissions to function properly. \
            You can continue without them, but some features may not work.

            You can grant permissions later in Settings.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Continue Anyway")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            return await openSystemSettings()
        }

        return status
    }

    // MARK: - Helper Methods

    /// Refresh permission status passively - only checks current status without triggering any dialogs
    /// Note: Screen recording cannot be checked passively, so we keep the last known state
    func refreshStatus() async {
        // Check microphone status passively (no dialog)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        status.microphone = micStatus == .authorized

        // Check accessibility passively (this is always passive)
        status.accessibility = checkAccessibilityPermission()

        // Screen recording: cannot check passively without triggering dialog
        // Keep the last known state - don't update status.screenRecording here
    }

    /// Show individual permission alert
    func showPermissionAlert(for type: PermissionType) {
        Task {
            // First, try to request the permission (this will show system dialog if not determined)
            switch type {
            case .microphone:
                let granted = await requestMicrophonePermission()
                if granted {
                    await refreshStatus()
                    return
                }
                // If denied, show alert to open settings
                
            case .accessibility:
                // Accessibility permission shows its own system dialog
                requestAccessibilityPermission()
                // Give it a moment to show the dialog
                try? await Task.sleep(for: .seconds(1))
                await refreshStatus()
                return
                
            case .screenRecording:
                let granted = await requestScreenRecordingPermission()
                if granted {
                    await refreshStatus()
                    return
                }
                // If denied, show alert to open settings
            }

            // If we get here, permission was denied - show alert to open System Settings
            await MainActor.run {
                showSettingsAlert(for: type)
            }
        }
    }
    
    /// Show alert to open System Settings for a permission that was denied
    private func showSettingsAlert(for type: PermissionType) {
        let alert = NSAlert()

        switch type {
        case .microphone:
            alert.messageText = "Microphone Access Required"
            alert.informativeText = """
                Diduny needs microphone access to record audio for transcription.

                Please enable it in System Settings > Privacy & Security > Microphone.
                """

        case .accessibility:
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = """
                To auto-paste transcribed text, Diduny needs accessibility permission.

                Please enable it in System Settings > Privacy & Security > Accessibility.
                """

        case .screenRecording:
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = """
                To record meeting audio, Diduny needs screen recording permission.

                Please enable it in System Settings > Privacy & Security > Screen Recording.
                """
        }

        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
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
}
