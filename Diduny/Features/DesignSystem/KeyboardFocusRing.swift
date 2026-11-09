import AppKit
import Observation
import SwiftUI

/// Floating panels draw a focus ring only after the person pressed Tab. With macOS keyboard navigation on, a key
/// window focuses its first control, so without this the ring shows on every open and click. Focus itself is kept.
@MainActor
@Observable
final class KeyboardFocusRing {
    static let shared = KeyboardFocusRing()
    private static let tabKeyCode: UInt16 = 48

    private(set) var isVisible = false

    /// For a panel's `sendEvent`.
    func note(_ event: NSEvent) {
        switch event.type {
        case .keyDown: note(keyCode: event.keyCode)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: hide()
        default: break
        }
    }

    func note(keyCode: UInt16) {
        if keyCode == Self.tabKeyCode { isVisible = true }
    }

    func hide() {
        isVisible = false
    }
}

private struct KeyboardFocusRingOnly: ViewModifier {
    func body(content: Content) -> some View {
        content.focusEffectDisabled(!KeyboardFocusRing.shared.isVisible)
    }
}

extension View {
    /// Root of a floating panel's content.
    func focusRingOnlyAfterTab() -> some View {
        modifier(KeyboardFocusRingOnly())
    }
}
