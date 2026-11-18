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
    /// What the pill says after an error.
    @Published var errorText = ""

    var title: String {
        switch state {
        case .translating: String(localized: "Translating…")
        case .success: String(localized: "Translated")
        case .error: errorText
        }
    }
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

    /// How long "Translated" stays, like the typing hints' receipts.
    static let successHold: TimeInterval = 1.2

    private var badgePanel: NSPanel?
    private var badgeSelectionEnd: CGRect?
    private let badgeModel = InplaceBadgeModel()
    private var toastPanel: NSPanel?
    private let toastModel = InplaceToastModel()
    private var toastTask: Task<Void, Never>?

    private init() {}

    // MARK: - Badge

    func showBadge(selectionEnd: CGRect?) {
        toastTask?.cancel()
        closeToast()
        badgeModel.state = .translating
        let size = Self.badgeSize(title: badgeModel.title)
        if badgePanel == nil {
            badgePanel = makePanel(rootView: InplaceBadgeView(model: badgeModel), size: size)
        }
        badgeSelectionEnd = selectionEnd
        badgePanel?.setFrame(badgeFrame(size: size, selectionEnd: selectionEnd), display: false)
        badgePanel?.orderFrontRegardless()
        badgeModel.isVisible = true
        announce(String(localized: "Translating"))
    }

    /// Glides the badge from its provisional (mouse) anchor to the selection end.
    func moveBadge(selectionEnd: CGRect?) {
        guard let panel = badgePanel, isBadgeShown, selectionEnd != nil else { return }
        badgeSelectionEnd = selectionEnd
        let target = badgeFrame(size: panel.frame.size, selectionEnd: selectionEnd)
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

    /// Plays the end state alongside the paste. Success: the ring closes with a check and sparks, the
    /// words become "Translated", held 1.2 s. Error (nil `failure` is success): red ring and shake, the
    /// pill says why, held as long as the old toast.
    func finishBadge(failure: InplaceTranslationToast?) async {
        guard isBadgeShown, let panel = badgePanel else { return }
        guard let failure else {
            badgeModel.state = .success
            announce(String(localized: "Translated"))
            try? await Task.sleep(for: .seconds(Self.successHold))
            return
        }
        // The pill grows to the reason; the panel first, so the words are never clipped.
        let size = Self.badgeSize(title: failure.text)
        if size.width > panel.frame.width {
            panel.setFrame(badgeFrame(size: size, selectionEnd: badgeSelectionEnd), display: true)
        }
        badgeModel.errorText = failure.text
        badgeModel.state = .error
        announce(failure.text, high: true)
        try? await Task.sleep(for: .seconds(failure.visibleSeconds))
    }

    func dismissBadge() async {
        guard isBadgeShown else { return }
        badgeModel.isVisible = false
        try? await Task.sleep(for: .seconds(0.15))
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
        let hosting = NSHostingView(rootView: rootView)
        // The controller sizes the panel; the hosting view never resizes it.
        hosting.sizingOptions = []
        panel.contentView = hosting
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

    /// The pill and its margin for `title`.
    static func badgeSize(title: String) -> CGSize {
        let fitting = NSHostingView(rootView: LogoPill(phase: .done, title: title, isOpen: true, isVisible: true).fixedSize()).fittingSize
        return CGSize(width: ceil(fitting.width), height: ceil(fitting.height))
    }

    /// The pill sits `gap` from the text; the panel adds the margin around it.
    private func badgeFrame(size: CGSize, selectionEnd: CGRect?) -> CGRect {
        let margin = LogoPill.margin
        let pill = CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin)
        return frame(size: pill, selectionEnd: selectionEnd).insetBy(dx: -margin, dy: -margin)
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

/// The logo pill: "Translating…" while the logo rocks, then the ring closes and the words become
/// "Translated". An error turns the ring red, shakes, and the pill says why.
private struct InplaceBadgeView: View {
    @ObservedObject var model: InplaceBadgeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shake: CGFloat = 0
    @State private var isOpen = false

    private var phase: LogoBadgePhase {
        switch model.state {
        case .translating: .waiting
        case .success: .done
        case .error: .error
        }
    }

    var body: some View {
        LogoPill(phase: phase, title: model.title, isOpen: isOpen, isVisible: model.isVisible)
            .offset(x: shake)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .task(id: model.isVisible) {
                // The logo pops first; the pill opens around it a moment later.
                guard model.isVisible else {
                    try? await Task.sleep(for: .seconds(0.2))
                    isOpen = false
                    return
                }
                if !reduceMotion { try? await Task.sleep(for: .milliseconds(120)) }
                isOpen = true
            }
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
