import AppKit
import ApplicationServices
import AVFAudio
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
    }

    // MARK: - Individual Permission Requests (Async)

    func requestMicrophonePermission() async -> Bool {
        let recordPermission = AVAudioApplication.shared.recordPermission

        switch recordPermission {
        case .granted:
            Log.permissions.info("Microphone permission already granted")
            return true

        case .undetermined:
            Log.permissions.info("Microphone permission not determined, requesting...")
            let granted = await AVAudioApplication.requestRecordPermission()
            Log.permissions.info("Microphone permission request result: \(granted)")
            return granted

        case .denied:
            Log.permissions.warning("Microphone permission denied")
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
    func ensureMicrophonePermission() async -> Bool {
        let recordPermission = AVAudioApplication.shared.recordPermission

        switch recordPermission {
        case .granted:
            return true

        case .undetermined:
            Log.permissions.info("Requesting microphone permission...")
            return await AVAudioApplication.requestRecordPermission()

        case .denied:
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
        let granted = await SystemAudioCaptureService.checkPermission()
        status.screenRecording = granted
        return granted
    }

    /// Request screen recording permission - this triggers the system permission dialog
    /// by attempting to access SCShareableContent
    func requestScreenRecordingPermission() async -> Bool {
        guard #available(macOS 13.0, *) else {
            Log.permissions.warning("Screen recording requires macOS 13.0+")
            return false
        }

        // Skip if already granted
        if status.screenRecording {
            Log.permissions.info("Screen recording permission already granted")
            return true
        }

        Log.permissions.info("Requesting screen recording permission...")

        // Calling SCShareableContent.excludingDesktopWindows triggers the permission dialog
        // if permission hasn't been determined yet
        let granted = await SystemAudioCaptureService.requestPermission()

        // Update cached status
        status.screenRecording = granted

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
