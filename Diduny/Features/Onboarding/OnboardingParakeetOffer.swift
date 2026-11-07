import AppKit
import SwiftUI

/// What the Ready screen shows for the Parakeet V3 offer (onboarding-parakeet.md "States").
enum ParakeetOfferPhase: Equatable {
    case hidden
    case notDownloaded
    case downloading(Double)
    case failed(String)
    case ready
    case skipped

    /// Hidden on Intel and when the model was already on disk as Ready appeared; "Not now" wins
    /// until a download runs (none can start from the skipped line).
    static func resolve(
        isSupportedHardware: Bool,
        downloadedWhenShown: Bool,
        skipped: Bool,
        state: ModelDownloadState
    ) -> Self {
        guard isSupportedHardware, !downloadedWhenShown else { return .hidden }
        switch state {
        case let .downloading(value): return .downloading(value)
        case .downloaded: return .ready
        case _ where skipped: return .skipped
        case let .failed(message): return .failed(message)
        case .notDownloaded: return .notDownloaded
        }
    }

    /// The accessibility value of `onboarding.modelOffer.parakeet-v3`.
    var accessibilityID: String {
        switch self {
        case .hidden: "hidden"
        case .notDownloaded: "notDownloaded"
        case .downloading: "downloading"
        case .failed: "failed"
        case .ready: "ready"
        case .skipped: "skipped"
        }
    }
}

/// The Parakeet V3 card under the shortcut badges. The download runs in `ParakeetModelController.shared`,
/// so it keeps going after the window closes.
struct OnboardingParakeetOffer: View {
    var controller: ParakeetModelController = .shared

    @State private var downloadedWhenShown: Bool?
    @State private var skipped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let id = "onboarding.modelOffer.parakeet-v3"

    private var phase: ParakeetOfferPhase {
        ParakeetOfferPhase.resolve(
            isSupportedHardware: controller.isSupportedHardware,
            downloadedWhenShown: downloadedWhenShown ?? (controller.state == .downloaded),
            skipped: skipped,
            state: controller.state
        )
    }

    var body: some View {
        content
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: phase)
            .onAppear {
                controller.refresh()
                if downloadedWhenShown == nil { downloadedWhenShown = controller.state == .downloaded }
            }
            .onChange(of: phase) { _, phase in
                switch phase {
                case .failed: announce(String(localized: "Parakeet V3 download failed"))
                case .ready: announce(String(localized: "Parakeet V3 is ready"))
                default: break
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .hidden:
            EmptyView()
        case .skipped:
            Text("Parakeet V3 is in Settings > Local models whenever you want it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(Self.id)
                .accessibilityValue(phase.accessibilityID)
        default:
            card
        }
    }

    private var title: LocalizedStringKey {
        phase == .ready ? "Parakeet V3 is ready" : "Download Parakeet V3, the fastest local model"
    }

    private var card: some View {
        HStack(spacing: 14) {
            Image(systemName: phase == .ready ? "checkmark.circle.fill" : "cpu")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(phase == .ready ? DS.Palette.ok : DS.Palette.accent)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .accessibilityIdentifier("\(Self.id).title")
                detail
                if case let .downloading(value) = phase {
                    progressBar(value).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            actions.fixedSize()
        }
        .padding(12)
        .background(OnboardingTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(phase.accessibilityID)
        .accessibilityIdentifier(Self.id)
    }

    @ViewBuilder
    private var detail: some View {
        switch phase {
        case let .failed(message):
            Text("Download failed. Try again, or download it later in Settings > Local models.")
                .font(.caption)
                .foregroundStyle(DS.Palette.no)
                .lineLimit(3)
                .help(message)
                .accessibilityHint(message)
                .accessibilityIdentifier("\(Self.id).failed")
        default:
            Text(detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(Self.id).detail")
        }
    }

    private var detailText: LocalizedStringKey {
        switch phase {
        case .downloading: "You can open Diduny now. The download continues in the background."
        case .ready: "It runs on this Mac. Choose where Diduny uses it in Settings > Modes."
        default: "Runs on this Mac, so audio never leaves it. 25 European languages, including Ukrainian. Diduny uses it for files, links and meetings recorded without live text."
        }
    }

    private func progressBar(_ value: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Palette.chip)
                Capsule().fill(DS.Palette.accent).frame(width: proxy.size.width * value)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel(Text("Downloading Parakeet V3"))
        .accessibilityValue(Text(percent(value)))
        .accessibilityIdentifier("\(Self.id).progress")
    }

    private func percent(_ value: Double) -> String {
        String(localized: "\(Int64((value * 100).rounded()))%")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch phase {
            case .notDownloaded:
                notNowButton
                primary(String(localized: "Download \(LocalModelSize.text(bytes: ParakeetProvider.downloadBytes))"), id: "download")
            case let .downloading(value):
                Text(percent(value))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Palette.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("\(Self.id).percent")
                Button("Cancel") { controller.cancel() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("\(Self.id).cancel")
            case .failed:
                notNowButton
                primary(String(localized: "Retry"), id: "retry")
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Palette.ok)
                    .accessibilityIdentifier("\(Self.id).ready")
            case .hidden, .skipped:
                EmptyView()
            }
        }
    }

    private var notNowButton: some View {
        Button("Not now") { skipped = true }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("\(Self.id).notNow")
    }

    private func primary(_ title: String, id: String) -> some View {
        Button(title) { controller.download() }
            .buttonStyle(.borderedProminent)
            .tint(DS.Palette.accentFill)
            .accessibilityIdentifier("\(Self.id).\(id)")
    }

    private func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp.mainWindow as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}
