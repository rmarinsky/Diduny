import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

struct PermissionsSettingsView: View {
    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false

    var body: some View {
        Form {
            Section {
                Text(
                    "Diduny requires certain permissions to function properly. Review the permissions below and grant any that are missing."
                )
                .foregroundColor(.secondary)
                .font(.callout)
            }

            Section("Required Permissions") {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone Access",
                    description: "Record audio for transcription or translation",
                    isGranted: $microphoneGranted,
                    permissionType: .microphone
                )

                PermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Auto-paste transcribed text",
                    isGranted: $accessibilityGranted,
                    permissionType: .accessibility
                )
                
                PermissionRow(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    description: "Transcribe meeting audio (macOS 13.0+)",
                    isGranted: $screenRecordingGranted,
                    permissionType: .screenRecording
                )
            }
        }
        .formStyle(.grouped)
        .task {
            await checkPermissionsPassive()
        }
    }

    /// Check permission status passively WITHOUT triggering any system dialogs
    /// Only updates local state based on current permission status
    private func checkPermissionsPassive() async {
        // Check microphone status without requesting (no dialog)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = micStatus == .authorized

        // Check accessibility (this is always passive)
        accessibilityGranted = AXIsProcessTrusted()

        // Screen recording: cannot check passively without triggering dialog
        // Show as not granted until user explicitly clicks Check
        // We'll keep the last known state if available, but don't check
        screenRecordingGranted = PermissionManager.shared.status.screenRecording
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    @Binding var isGranted: Bool
    let permissionType: PermissionType

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(isGranted ? .green : .orange)
                .frame(width: 32)

            // Title and description
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Status and action button
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            } else {
                Button("Check") {
                    Task {
                        await checkAndUpdatePermission()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    /// Check permission and update the binding if granted
    private func checkAndUpdatePermission() async {
        let granted: Bool

        switch permissionType {
        case .microphone:
            granted = await PermissionManager.shared.requestMicrophonePermission()

        case .accessibility:
            // First check if already granted
            if AXIsProcessTrusted() {
                granted = true
            } else {
                // Only show dialog if not yet granted
                PermissionManager.shared.requestAccessibilityPermission()
                // Bring our app back to front after System Settings opens
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    NSApp.activate(ignoringOtherApps: true)
                }
                // Give time for the user to respond
                try? await Task.sleep(for: .milliseconds(500))
                granted = AXIsProcessTrusted()
            }

        case .screenRecording:
            granted = await PermissionManager.shared.requestScreenRecordingPermission()
            // Bring our app back to front if System Settings was opened
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        await MainActor.run {
            isGranted = granted
        }
    }
}

#Preview {
    PermissionsSettingsView()
}
