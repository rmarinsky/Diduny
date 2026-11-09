import AppKit
import SwiftUI

/// Toast content for the in-place translation flow.
enum InplaceTranslationToast: Equatable {
    case nothingSelected
    case networkFailure
    case quotaFailure

    var text: String {
        switch self {
        case .nothingSelected: String(localized: "Select text to translate")
        case .networkFailure: String(localized: "Translation failed. Original text kept.")
        case .quotaFailure: String(localized: "Translation limit reached. Original text kept.")
        }
    }

    var symbol: String {
        self == .nothingSelected ? "text.cursor" : "exclamationmark.triangle.fill"
    }

    var isError: Bool {
        self != .nothingSelected
    }

    var visibleSeconds: Double {
        isError ? 3.0 : 2.0
    }
}

@MainActor
final class InplaceBadgeModel: ObservableObject {
    enum State { case translating, success, error }
    @Published var state: State = .translating
    @Published var isVisible = false
    @Published var pulses = 0
}

@MainActor
final class InplaceToastModel: ObservableObject {
    @Published var toast: InplaceTranslationToast = .nothingSelected
    @Published var isVisible = false
}

/// Non-activating panels (progress badge + toast). Never takes focus, so the paste lands in the target app.
@MainActor
final class InplaceTranslationFeedbackController {
    static let shared = InplaceTranslationFeedbackController()

    private final class FeedbackPanel: NSPanel {
        override var canBecomeKey: Bool {
            false
        }

        override var canBecomeMain: Bool {
            false
        }
    }

    /// The 42 pt logo disc plus room for the 1.15 pulse (stop animation: one size for every mode).
    static let badgeSize = CGSize(
        width: PasteMarkPlan.disc + 2 * PasteMarkPlan.panelMargin,
        height: PasteMarkPlan.disc + 2 * PasteMarkPlan.panelMargin
    )

    private var badgePanel: NSPanel?
    private let badgeModel = InplaceBadgeModel()
    private var toastPanel: NSPanel?
    private let toastModel = InplaceToastModel()
    private var toastTask: Task<Void, Never>?

    private init() {}

    // MARK: - Badge

    func showBadge(selectionEnd: CGRect?) {
        toastTask?.cancel()
        closeToast()
        if badgePanel == nil {
            badgePanel = makePanel(rootView: InplaceBadgeView(model: badgeModel), size: Self.badgeSize)
        }
        badgeModel.state = .translating
        badgePanel?.setFrame(badgeFrame(selectionEnd: selectionEnd), display: false)
        badgePanel?.orderFrontRegardless()
        badgeModel.isVisible = true
        announce(String(localized: "Translating"))
    }

    /// Glides the badge from its provisional (mouse) anchor to the selection end.
    func moveBadge(selectionEnd: CGRect?) {
        guard let panel = badgePanel, isBadgeShown, selectionEnd != nil else { return }
        let target = badgeFrame(selectionEnd: selectionEnd)
        guard target != panel.frame else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().setFrame(target, display: true)
        }
    }

    var isBadgeShown: Bool {
        badgePanel?.isVisible == true
    }

    /// Plays the end state alongside the paste. Success: the ring closes, one pulse at 220 ms,
    /// held until the 680 ms fade (stop animation). Error holds 0.7 s.
    func finishBadge(success: Bool) async {
        guard isBadgeShown else { return }
        badgeModel.state = success ? .success : .error
        announce(success ? String(localized: "Translated") : String(localized: "Translation failed"))
        guard success else {
            try? await Task.sleep(for: .milliseconds(700))
            return
        }
        let timeline = PasteMarkPlan.timeline(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if timeline.pulse > 0 {
            try? await Task.sleep(for: .seconds(timeline.pulseStart))
            badgeModel.pulses += 1
        }
        try? await Task.sleep(for: .seconds(timeline.fadeStart - (timeline.pulse > 0 ? timeline.pulseStart : 0)))
    }

    func dismissBadge() async {
        guard isBadgeShown else { return }
        badgeModel.isVisible = false
        try? await Task.sleep(for: .seconds(PasteMarkPlan.timeline(reduceMotion: false).fade))
        badgePanel?.orderOut(nil)
    }

    // MARK: - Toast

    func showToast(_ toast: InplaceTranslationToast, selectionEnd: CGRect?) {
        toastTask?.cancel()
        toastModel.toast = toast
        let size = NSHostingView(rootView: InplaceToastView(model: toastModel)).fittingSize
        if toastPanel == nil {
            toastPanel = makePanel(rootView: InplaceToastView(model: toastModel), size: size)
        }
        position(toastPanel, size: size, selectionEnd: selectionEnd)
        toastPanel?.orderFrontRegardless()
        toastModel.isVisible = true
        announce(toast.text, high: toast.isError)

        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.visibleSeconds))
            guard !Task.isCancelled else { return }
            self?.toastModel.isVisible = false
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.closeToast()
        }
    }

    private func closeToast() {
        toastModel.isVisible = false
        toastPanel?.orderOut(nil)
    }

    // MARK: - Panels

    private func makePanel(rootView: some View, size: CGSize) -> NSPanel {
        let panel = FeedbackPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: rootView)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func position(_ panel: NSPanel?, size: CGSize, selectionEnd: CGRect?) {
        panel?.setFrame(frame(size: size, selectionEnd: selectionEnd), display: false)
    }

    /// The disc sits `gap` from the text; the panel adds the pulse margin around it.
    private func badgeFrame(selectionEnd: CGRect?) -> CGRect {
        let disc = CGSize(width: PasteMarkPlan.disc, height: PasteMarkPlan.disc)
        return frame(size: disc, selectionEnd: selectionEnd)
            .insetBy(dx: -PasteMarkPlan.panelMargin, dy: -PasteMarkPlan.panelMargin)
    }

    private func frame(size: CGSize, selectionEnd: CGRect?) -> CGRect {
        let screens = NSScreen.screens.map {
            InplaceTranslationAnchor.ScreenInfo(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        return InplaceTranslationAnchor.panelFrame(
            size: size, selectionEnd: selectionEnd, mouse: NSEvent.mouseLocation, screens: screens
        )
    }

    private func announce(_ text: String, high: Bool = false) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: (high ? NSAccessibilityPriorityLevel.high : .medium).rawValue
            ]
        )
    }
}

// MARK: - Views

/// The app logo on its disc (stop animation): the rim arc while translating, then the ring closes
/// and pulses once. An error keeps the red ring and the shake.
private struct InplaceBadgeView: View {
    @ObservedObject var model: InplaceBadgeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shake: CGFloat = 0

    private var phase: LogoBadgePhase {
        switch model.state {
        case .translating: .waiting
        case .success: .done
        case .error: .error
        }
    }

    var body: some View {
        LogoBadge(phase: phase, isVisible: model.isVisible, pulseTrigger: model.pulses)
            .offset(x: shake)
            .frame(
                width: InplaceTranslationFeedbackController.badgeSize.width,
                height: InplaceTranslationFeedbackController.badgeSize.height
            )
            .task(id: model.state) {
                guard model.state == .error, !reduceMotion else { return }
                for offset: CGFloat in [3, -3, 3, -3, 0] {
                    withAnimation(.linear(duration: 0.06)) { shake = offset }
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
    }
}

private struct InplaceToastView: View {
    @ObservedObject var model: InplaceToastModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.toast.symbol)
                .foregroundStyle(model.toast.isError ? Color.orange : Color.secondary)
            Text(model.toast.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color("BrandTintBorder"), lineWidth: 0.5)
        }
        .fixedSize()
        .offset(y: reduceMotion || model.isVisible ? 0 : 6)
        .opacity(model.isVisible ? 1 : 0)
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.15)
                : (model.isVisible ? .spring(response: 0.3, dampingFraction: 0.8) : .easeIn(duration: 0.2)),
            value: model.isVisible
        )
        .accessibilityHidden(true)
    }
}
