import AppKit

/// The modifier pair of "Switch layout of selected text", pressed together 2 or 3 times.
/// Raw values are Papuga's `doublePressShortcut` values.
enum TypingConvertPair: String, CaseIterable, Identifiable {
    case optionShift, commandShift, controlShift

    var id: String { rawValue }

    var families: ModifierFamilies {
        switch self {
        case .optionShift: [.option, .shift]
        case .commandShift: [.command, .shift]
        case .controlShift: [.control, .shift]
        }
    }
}

/// Listens for the Convert pair pressed 2 or 3 times (Papuga's `HotkeyListener`), on Diduny's own key monitors.
/// Left and right keys both count. Any other key or modifier in between starts over.
final class TypingConvertMonitor {
    /// Papuga's `doublePressInterval`.
    static let threshold: TimeInterval = 0.4

    private let source: KeyEventSource
    private let captureSession: ShortcutCaptureSession
    private var gesture = InplaceTranslationGesture()
    private(set) var pair: TypingConvertPair?
    private var pressCount = 2

    var onTrigger: (() -> Void)?

    init(
        source: KeyEventSource = NSEventKeySource([.flagsChanged, .keyDown]),
        captureSession: ShortcutCaptureSession = .shared
    ) {
        self.source = source
        self.captureSession = captureSession
    }

    /// Listens for `pair` pressed `pressCount` times; nil stops.
    func listen(for pair: TypingConvertPair?, pressCount: Int = 2) {
        guard pair != self.pair || pressCount != self.pressCount || (pair != nil) != source.isActive else { return }
        source.stop()
        self.pair = pair
        self.pressCount = pressCount
        guard let pair else { return }
        gesture = InplaceTranslationGesture(threshold: Self.threshold, chord: .init(pair.families), pressCount: pressCount)
        source.start { [weak self] event in self?.handle(event) }
    }

    private func handle(_ event: KeyEvent) {
        guard let pair, !captureSession.isActive else {
            gesture.reset()
            return
        }
        let gestureEvent: InplaceTranslationGesture.Event = switch event {
        case .keyDown:
            .keyDown
        case let .flagsChanged(_, flagsRawValue, timestamp):
            .modifiersChanged(
                InplaceTranslationHotkeyMonitor.modifiers(from: NSEvent.ModifierFlags(rawValue: flagsRawValue), chord: pair.families),
                at: timestamp
            )
        }
        if gesture.handle(gestureEvent) { onTrigger?() }
    }
}
