import AppKit

/// A recording's start: the app logo on its disc opens into the live panel (Roman, 2026-11-09).
/// The panel is already fully drawn and capture is not waited for. The motion is Core Animation
/// committed to the render server, so a main thread held by the microphone (`c93b32e`) cannot
/// freeze it half way; the final state is the plain panel.
enum EdgeCommandPanelLogoEntrance {
    static let duration: TimeInterval = 0.24
    static let logoFade: TimeInterval = 0.14
    static let logoDisc: CGFloat = 28

    /// The disc's start (view coordinates, bottom-left origin): over the header icon tile.
    static func startDisc(in bounds: CGRect) -> CGRect {
        let inset = DS.Panel.padding
        return CGRect(
            x: bounds.minX + inset,
            y: bounds.maxY - inset - logoDisc,
            width: logoDisc,
            height: logoDisc
        )
    }

    @MainActor
    static func play(on view: NSView, cornerRadius: CGFloat) {
        guard let layer = view.layer, view.bounds.width > logoDisc, view.bounds.height > logoDisc else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = PasteMarkPlan.timeline(reduceMotion: true).fade
            layer.add(fade, forKey: "logoEntrance")
            CATransaction.commit()
            return
        }

        let bounds = view.bounds
        let start = startDisc(in: bounds)
        let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1) // DS.Motion.easeOut

        let mask = CAShapeLayer()
        mask.frame = bounds
        let from = CGPath(ellipseIn: start, transform: nil)
        let to = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        mask.path = to
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = from
        grow.toValue = to
        grow.duration = duration
        grow.timingFunction = curve
        mask.add(grow, forKey: "grow")

        let logo = logoLayer(frame: start, appearance: view.effectiveAppearance)
        logo.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = logoFade
        fade.timingFunction = curve
        logo.add(fade, forKey: "fade")

        layer.mask = mask
        layer.addSublayer(logo)
        CATransaction.setCompletionBlock {
            if layer.mask === mask { layer.mask = nil }
            logo.removeFromSuperlayer()
        }
        CATransaction.commit()
    }

    @MainActor
    private static func logoLayer(frame: CGRect, appearance: NSAppearance) -> CALayer {
        let disc = CALayer()
        disc.frame = frame
        disc.cornerRadius = frame.width / 2
        disc.zPosition = 100
        appearance.performAsCurrentDrawingAppearance {
            disc.backgroundColor = NSColor.windowBackgroundColor.cgColor
            disc.borderColor = (NSColor(named: "BrandTintBorder") ?? .separatorColor).cgColor
        }
        disc.borderWidth = 0.5
        let icon = CALayer()
        let side = frame.width * 18 / 28
        icon.frame = CGRect(x: (frame.width - side) / 2, y: (frame.height - side) / 2, width: side, height: side)
        icon.contents = NSApp.applicationIconImage
        icon.contentsGravity = .resizeAspect
        disc.addSublayer(icon)
        return disc
    }
}
