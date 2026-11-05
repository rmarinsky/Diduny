import AppKit
import SwiftUI

struct OverviewLaunchCard: View {
    @State private var onboarding = OnboardingManager.shared
    @State private var updateArrival = UpdateArrivalState.shared
    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var permissionsLoaded = false

    private var allPermissionsGranted: Bool {
        microphoneGranted && accessibilityGranted && screenRecordingGranted
    }

    private let releaseHighlights = ReleaseHighlights.bundled()

    var body: some View {
        VStack(spacing: 12) {
            // Nothing to act on once everything is allowed, so the card steps aside.
            if permissionsLoaded, !(allPermissionsGranted && onboarding.hasCompletedOnboarding) {
                permissionStatusCard
            }
            if onboarding.canShowUpdateHighlights,
               let releaseLine = updateArrival.pendingReleaseLine,
               let releaseHighlights
            {
                whatsNewCard(releaseLine: releaseLine, highlights: releaseHighlights)
            }
        }
        .task { await refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermissions() }
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
                .buttonStyle(.bordered)
                .accessibilityHint("Opens the setup guide in a separate window")
            }

            HStack(spacing: 18) {
                status("Microphone", icon: "mic.fill", granted: microphoneGranted)
                status("Accessibility", icon: "accessibility", granted: accessibilityGranted)
                status("Screen Recording", icon: "rectangle.on.rectangle", granted: screenRecordingGranted)
            }
        }
        .padding(DS.Space.lg)
        .background(DS.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.cardBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
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
        HStack(alignment: .top, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color("BrandAccentDeep"))
                        .accessibilityHidden(true)
                    Text("What’s New in Diduny \(releaseLine)")
                        .font(DS.Font.headline)
                    Spacer(minLength: 0)
                    Button {
                        updateArrival.dismissPendingRelease()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss What’s New for Diduny \(releaseLine)")
                }
                Text(LocalizedStringKey(highlights.headline))
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(highlights.highlights.enumerated()), id: \.offset) { _, highlight in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(Color("BrandAccentDeep"))
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(highlight))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(DS.Font.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let demo = Bundle.main.image(forResource: "ReleaseDemo") {
                AnimatedImage(image: demo)
                    .aspectRatio(demo.size.width / max(demo.size.height, 1), contentMode: .fit)
                    .frame(width: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color("BrandTintBorder"), lineWidth: 1)
                    }
                    .accessibilityLabel("What’s new in this release, animated")
            }
        }
        .padding(DS.Space.lg)
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
        permissionsLoaded = true
    }
}

/// Plays a bundled animated GIF (NSImageView animates GIFs natively; SwiftUI's Image does not).
private struct AnimatedImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = image
        view.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}
