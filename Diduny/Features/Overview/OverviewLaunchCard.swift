import AppKit
import SwiftUI

struct OverviewLaunchCard: View {
    @State private var onboarding = OnboardingManager.shared
    @State private var updateArrival = UpdateArrivalState.shared
    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false

    private let releaseHighlights = ReleaseHighlights.bundled()

    var body: some View {
        VStack(spacing: 12) {
            permissionStatusCard
            if onboarding.canShowUpdateHighlights,
               let releaseLine = updateArrival.pendingReleaseLine,
               let releaseHighlights
            {
                whatsNewCard(releaseLine: releaseLine, highlights: releaseHighlights)
            }
        }
    }

    private var permissionStatusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(onboarding.hasCompletedOnboarding ? "Diduny permissions" : "Finish setting up Diduny")
                        .font(.headline)
                    Text("Permissions are used only when their feature needs them.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Setup Guide") {
                    OnboardingWindowController.shared.showOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens the setup guide in a separate window")
            }

            HStack(spacing: 18) {
                status("Microphone", icon: "mic.fill", granted: microphoneGranted)
                status("Accessibility", icon: "accessibility", granted: accessibilityGranted)
                status("Screen Recording", icon: "rectangle.on.rectangle", granted: screenRecordingGranted)
            }
        }
        .padding(16)
        .background(Color(.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .task { await refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermissions() }
        }
    }

    private func status(_ title: LocalizedStringKey, icon: String, granted: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(granted ? "Allowed" : "Not allowed")
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .secondary)
            }
        } icon: {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .foregroundStyle(granted ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func whatsNewCard(releaseLine: String, highlights: ReleaseHighlights) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Color("BrandAccentDeep"))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text("What’s New in Diduny \(releaseLine)")
                    .font(.title3.bold())
                Text(LocalizedStringKey(highlights.headline))
                    .font(.headline)
                ForEach(Array(highlights.highlights.enumerated()), id: \.offset) { _, highlight in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(highlight))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                updateArrival.dismissPendingRelease()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss What’s New for Diduny \(releaseLine)")
        }
        .padding(20)
        .background(Color("BrandTintSoft"))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color("BrandTintBorder"), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func refreshPermissions() async {
        await PermissionManager.shared.refreshStatus()
        microphoneGranted = PermissionManager.shared.status.microphone
        accessibilityGranted = PermissionManager.shared.status.accessibility
        screenRecordingGranted = PermissionManager.shared.status.screenRecording
    }
}
