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

    /// 28pt badge plus room for the success burst.
    private static let badgeSize = CGSize(width: 44, height: 44)

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
        position(badgePanel, size: Self.badgeSize, selectionEnd: selectionEnd)
        badgePanel?.orderFrontRegardless()
        badgeModel.isVisible = true
        announce(String(localized: "Translating"))
    }

    /// Glides the badge from its provisional (mouse) anchor to the selection end.
    func moveBadge(selectionEnd: CGRect?) {
        guard let panel = badgePanel, isBadgeShown, selectionEnd != nil else { return }
        let target = frame(size: Self.badgeSize, selectionEnd: selectionEnd)
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

    /// Plays the end state. Success holds 380 ms (runs alongside the paste), error holds 0.7 s.
    func finishBadge(success: Bool) async {
        guard isBadgeShown else { return }
        badgeModel.state = success ? .success : .error
        announce(success ? String(localized: "Translated") : String(localized: "Translation failed"))
        try? await Task.sleep(for: .milliseconds(success ? 380 : 700))
    }

    func dismissBadge() async {
        guard isBadgeShown else { return }
        badgeModel.isVisible = false
        try? await Task.sleep(for: .milliseconds(200))
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

/// Timeline: pop-in (spring overshoot) → thinking loop (spinning arc, orbiting dots,
/// breathing logo with a tilt) → success (check pop + burst) or error (shake).
private struct InplaceBadgeView: View {
    @ObservedObject var model: InplaceBadgeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var breathing = false
    @State private var shake: CGFloat = 0
    @State private var burst = false

    private var ringColor: Color {
        if model.state == .error { return .red }
        return colorScheme == .dark ? Color("BrandTintSoft").opacity(0.9) : Color("BrandAccentDeep")
    }

    private var isThinking: Bool {
        model.isVisible && model.state == .translating && !reduceMotion
    }

    var body: some View {
        ZStack {
            if model.state == .success, !reduceMotion { burstView }
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().stroke(Color("BrandTintBorder"), lineWidth: 0.5)
                // Paused (no frames) whenever the badge is not thinking.
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isThinking)) { timeline in
                    thinking(t: timeline.date.timeIntervalSinceReferenceDate)
                }
                ring
                if model.state == .success {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, ringColor)
                        .offset(x: 9, y: 9)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .frame(width: 28, height: 28)
        }
        .frame(width: 44, height: 44)
        .offset(x: shake)
        .scaleEffect(scale)
        .opacity(model.isVisible ? 1 : 0)
        .animation(appearAnimation, value: model.isVisible)
        .animation(reduceMotion ? nil : .bouncy(duration: 0.3, extraBounce: 0.15), value: model.state)
        .accessibilityHidden(true)
        .onAppear {
            guard reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathing = true }
        }
        .task(id: model.state) { await runStateEffects() }
    }

    /// Logo + orbiting dots, driven by the timeline clock (60 fps cap).
    private func thinking(t: Double) -> some View {
        let animate = model.state == .translating && !reduceMotion
        let phase = t.truncatingRemainder(dividingBy: 0.9) / 0.9 // one orbit per 0.9 s
        let pulse = animate ? (sin(t * 2 * .pi / 0.9) + 1) / 2 : 0
        return ZStack {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 18, height: 18)
                .scaleEffect(1 + 0.08 * pulse)
                .rotationEffect(.degrees(animate ? sin(t * 2 * .pi / 1.8) * 6 : 0))
                .opacity(reduceMotion && model.state == .translating ? (breathing ? 0.6 : 1.0) : 1)
            if animate {
                ForEach(0..<3, id: \.self) { i in
                    let angle = (phase - Double(i) * 0.08) * 2 * .pi
                    Circle()
                        .fill(ringColor)
                        .frame(width: 3.5 - Double(i), height: 3.5 - Double(i))
                        .opacity(1 - Double(i) * 0.3)
                        .offset(x: cos(angle) * 14, y: sin(angle) * 14)
                }
            }
        }
    }

    @ViewBuilder
    private var ring: some View {
        if reduceMotion {
            if model.state == .error { Circle().stroke(ringColor, lineWidth: 1.5) }
        } else if model.state != .translating {
            Circle().stroke(ringColor, lineWidth: 1.5)
                .transition(.opacity)
        }
    }

    /// Six sparks that fly out and fade when the paste lands.
    private var burstView: some View {
        ForEach(0..<6, id: \.self) { i in
            let angle = Double(i) / 6 * 2 * .pi
            Circle()
                .fill(ringColor)
                .frame(width: 3, height: 3)
                .offset(x: cos(angle) * (burst ? 20 : 12), y: sin(angle) * (burst ? 20 : 12))
                .opacity(burst ? 0 : 1)
        }
    }

    private var scale: CGFloat {
        if reduceMotion { return 1 }
        if !model.isVisible { return 0.4 }
        return model.state == .success ? 1.15 : 1
    }

    private var appearAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        return model.isVisible ? .bouncy(duration: 0.28, extraBounce: 0.2) : .easeIn(duration: 0.15)
    }

    private func runStateEffects() async {
        burst = false
        guard !reduceMotion else { return }
        switch model.state {
        case .translating:
            return
        case .success:
            withAnimation(.easeOut(duration: 0.35)) { burst = true }
        case .error:
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
