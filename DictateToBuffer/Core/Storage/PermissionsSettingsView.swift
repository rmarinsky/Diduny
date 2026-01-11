import SwiftUI

struct PermissionsSettingsView: View {
    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var notificationsGranted = false
    
    var body: some View {
        Form {
            Section {
                Text("DictateToBuffer requires certain permissions to function properly. Review the permissions below and grant any that are missing.")
                    .foregroundColor(.secondary)
                    .font(.callout)
            }
            
            Section("Required Permissions") {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone Access",
                    description: "Record audio for transcription",
                    isGranted: microphoneGranted,
                    permissionType: .microphone
                )
                
                PermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Auto-paste transcribed text",
                    isGranted: accessibilityGranted,
                    permissionType: .accessibility
                )
            }
            
            Section("Optional Permissions") {
                PermissionRow(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    description: "Record meeting audio (macOS 13.0+)",
                    isGranted: screenRecordingGranted,
                    permissionType: .screenRecording
                )
                
                PermissionRow(
                    icon: "bell.fill",
                    title: "Notifications",
                    description: "Show transcription completion alerts",
                    isGranted: notificationsGranted,
                    permissionType: .notifications
                )
            }
            
            Section {
                Button("Refresh Permission Status") {
                    Task {
                        await refreshPermissions()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshPermissions()
        }
    }
    
    private func refreshPermissions() async {
        await PermissionManager.shared.refreshStatus()
        
        // Update local state
        microphoneGranted = PermissionManager.shared.status.microphone
        accessibilityGranted = PermissionManager.shared.status.accessibility
        screenRecordingGranted = PermissionManager.shared.status.screenRecording
        notificationsGranted = PermissionManager.shared.status.notifications
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
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
                Button("Grant") {
                    PermissionManager.shared.showPermissionAlert(for: permissionType)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    PermissionsSettingsView()
}
