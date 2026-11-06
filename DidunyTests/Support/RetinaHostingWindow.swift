import AppKit
import SwiftUI

/// A borderless window that is never ordered front and reports a Retina backing scale. SwiftUI
/// snaps text and frames to the pixel grid of the window's scale (whole points without a
/// window), so a view hosted here measures and renders as on a 2x Mac, whatever display the
/// runner has. It never becomes key and takes no events, so suites using it need no UI gate.
final class RetinaHostingWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }

    @MainActor
    init(hosting view: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 800),
                   styleMask: [.borderless], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        contentView = view
    }
}

@MainActor
enum RetinaHost {
    /// `NSHostingView.fittingSize` of `view` inside a `RetinaHostingWindow`.
    static func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        let window = RetinaHostingWindow(hosting: host)
        defer { window.contentView = nil }
        return host.fittingSize
    }

    /// Lays `view` out at its fitting size inside a `RetinaHostingWindow` and draws it once,
    /// which also evaluates every `GeometryReader` in it. Returns the 2x bitmap.
    static func render(_ view: some View, appearance: NSAppearance? = nil) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        let window = RetinaHostingWindow(hosting: host)
        defer { window.contentView = nil }
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard host.bounds.width > 0, host.bounds.height > 0,
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
}
