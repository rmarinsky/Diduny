import AppKit
import SwiftUI

/// Floating keyboard-first picker for choosing which language pair to
/// translate into. Shown by the translation hotkey when more than one pair is
/// configured; push-to-talk deliberately skips it (recording must start
/// instantly while keys are held).
///
/// Keys: ↑/↓ move, 1–9 select directly, ⏎ confirms, esc cancels. Pressing the
/// translation hotkey again while the picker is open confirms the highlighted
/// pair, so "hotkey, hotkey" starts recording with the default pair.
@MainActor
final class TranslationPairPickerController: NSObject, NSWindowDelegate {
    static let shared = TranslationPairPickerController()

    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var model: TranslationPairPickerModel?
    private var continuation: CheckedContinuation<TranslationLanguagePair?, Never>?

    override private init() {
        super.init()
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    /// Shows the picker and suspends until the user picks a pair or cancels.
    /// Returns nil on cancel. Reentrant calls cancel the previous invocation.
    func pick(
        pairs: [TranslationLanguagePair],
        preselected: TranslationLanguagePair?
    ) async -> TranslationLanguagePair? {
        dismiss(returning: nil)

        guard !pairs.isEmpty else { return nil }
        guard SettingsStorage.shared.effectiveTranslationProvider == .cloud else {
            return preselected ?? pairs.first
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            show(pairs: pairs, preselected: preselected)
        }
    }

    /// Confirms the currently highlighted pair (used by a repeated hotkey press).
    func confirmCurrentSelection() {
        guard let model else { return }
        dismiss(returning: model.selectedPair)
    }

    private func show(pairs: [TranslationLanguagePair], preselected: TranslationLanguagePair?) {
        let model = TranslationPairPickerModel(
            pairs: pairs,
            selectedIndex: pairs.firstIndex(where: { $0.id == preselected?.id }) ?? 0
        )
        model.onCommit = { [weak self] pair in
            self?.dismiss(returning: pair)
        }
        self.model = model

        let hostingView = NSHostingView(rootView: TranslationPairPickerPanelView(model: model))
        hostingView.setFrameSize(hostingView.fittingSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.titled, .hudWindow, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Translate to"
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = false
        panel.center()
        panel.delegate = self
        self.panel = panel
        // Non-activating panel: takes key events without stealing app focus,
        // so the eventual paste still lands in the user's frontmost app.
        panel.makeKeyAndOrderFront(nil)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model else { return event }

            switch event.keyCode {
            case 53: // Escape
                self.dismiss(returning: nil)
                return nil
            case 36, 76: // Return / keypad Enter
                self.dismiss(returning: model.selectedPair)
                return nil
            case 126: // Up
                model.moveSelection(by: -1)
                return nil
            case 125: // Down
                model.moveSelection(by: 1)
                return nil
            default:
                if let characters = event.charactersIgnoringModifiers,
                   let digit = Int(characters), (1 ... 9).contains(digit),
                   digit <= model.pairs.count {
                    self.dismiss(returning: model.pairs[digit - 1])
                    return nil
                }
                return event
            }
        }
    }

    /// Resolves the pending pick exactly once and tears the panel down.
    private func dismiss(returning pair: TranslationLanguagePair?) {
        let continuation = self.continuation
        self.continuation = nil
        model = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        panel?.delegate = nil
        panel?.close()
        panel = nil
        continuation?.resume(returning: pair)
    }

    nonisolated func windowWillClose(_: Notification) {
        Task { @MainActor in
            // Closed by the system (e.g. app hide) without an explicit choice.
            self.dismiss(returning: nil)
        }
    }
}

// MARK: - Model

@Observable
@MainActor
final class TranslationPairPickerModel {
    let pairs: [TranslationLanguagePair]
    var selectedIndex: Int
    var onCommit: ((TranslationLanguagePair?) -> Void)?

    init(pairs: [TranslationLanguagePair], selectedIndex: Int) {
        self.pairs = pairs
        self.selectedIndex = min(max(selectedIndex, 0), max(pairs.count - 1, 0))
    }

    var selectedPair: TranslationLanguagePair? {
        pairs.indices.contains(selectedIndex) ? pairs[selectedIndex] : pairs.first
    }

    func moveSelection(by delta: Int) {
        guard !pairs.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + pairs.count) % pairs.count
    }
}
