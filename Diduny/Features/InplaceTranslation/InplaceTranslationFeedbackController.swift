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

    private static let badgeSize = CGSize(width: 28, height: 28)

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

    var isBadgeShown: Bool {
        badgePanel?.isVisible == true
    }

    /// Plays the end state. Success holds 120 ms (paste follows), error holds 0.7 s.
    func finishBadge(success: Bool) async {
        guard isBadgeShown else { return }
        badgeModel.state = success ? .success : .error
        announce(success ? String(localized: "Translated") : String(localized: "Translation failed"))
        try? await Task.sleep(for: .milliseconds(success ? 120 : 700))
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
        let screens = NSScreen.screens.map {
            InplaceTranslationAnchor.ScreenInfo(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let frame = InplaceTranslationAnchor.panelFrame(
            size: size, selectionEnd: selectionEnd, mouse: NSEvent.mouseLocation, screens: screens
        )
        panel?.setFrame(frame, display: false)
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

private struct InplaceBadgeView: View {
    @ObservedObject var model: InplaceBadgeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var rotation = 0.0
    @State private var breathing = false
    @State private var shake: CGFloat = 0

    private var ringColor: Color {
        if model.state == .error { return .red }
        return colorScheme == .dark ? Color("BrandTintSoft").opacity(0.9) : Color("BrandAccentDeep")
    }

    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            Circle().stroke(Color("BrandTintBorder"), lineWidth: 0.5)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 18, height: 18)
                .scaleEffect(reduceMotion ? 1 : (breathing ? 1.08 : 1.0))
                .opacity(reduceMotion && model.state == .translating ? (breathing ? 0.6 : 1.0) : 1)

            ring
            if model.state == .success {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ringColor)
                    .offset(x: 7, y: 7)
            }
        }
        .frame(width: 28, height: 28)
        .offset(x: shake)
        .scaleEffect(scale)
        .opacity(model.isVisible ? 1 : 0)
        .animation(appearAnimation, value: model.isVisible)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: model.state)
        .accessibilityHidden(true)
        .onAppear(perform: startLoops)
        .task(id: model.state) { await runStateEffects() }
    }

    @ViewBuilder
    private var ring: some View {
        if reduceMotion {
            if model.state == .error { Circle().stroke(ringColor, lineWidth: 1.5) }
        } else if model.state == .translating {
            Circle().trim(from: 0, to: 0.3)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(rotation))
        } else {
            Circle().stroke(ringColor, lineWidth: 1.5)
        }
    }

    private var scale: CGFloat {
        if reduceMotion { return 1 }
        if !model.isVisible { return 0.85 }
        return model.state == .success ? 1.12 : 1
    }

    private var appearAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        return model.isVisible ? .spring(response: 0.28, dampingFraction: 0.72) : .easeIn(duration: 0.18)
    }

    private func startLoops() {
        if reduceMotion {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathing = true }
        } else {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathing = true }
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) { rotation = 360 }
        }
    }

    private func runStateEffects() async {
        guard model.state == .error, !reduceMotion else { return }
        for offset: CGFloat in [3, -3, 3, -3, 0] {
            withAnimation(.linear(duration: 0.06)) { shake = offset }
            try? await Task.sleep(for: .milliseconds(60))
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
