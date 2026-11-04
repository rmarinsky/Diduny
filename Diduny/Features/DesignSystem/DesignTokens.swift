import SwiftUI

/// Layout standard for the main window. Source: docs/design/ui-unification/README.md.
enum DS {
    /// Spacing scale: 4 / 8 / 12 / 16 / 24 only.
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 12
        static let sidebarRow: CGFloat = 6
    }

    enum Layout {
        static let sidebarWidth: CGFloat = 238
        static let pagePadding: CGFloat = Space.xl
        /// Inner content column; the outer box adds the 24 pt page insets on both sides.
        static let columnMaxWidth: CGFloat = 840
        static let outerColumnMaxWidth: CGFloat = columnMaxWidth + pagePadding * 2
        static let settingRowMinHeight: CGFloat = 44
    }

    /// Four type levels: title, headline, body, secondary (callout 12 / caption 11).
    enum Font {
        static let pageTitle = SwiftUI.Font.system(size: 22, weight: .bold)
        static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let callout = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
    }

    enum Palette {
        static let accent = Color("BrandAccentDeep")
        static let tintSoft = Color("BrandTintSoft")
        static let tintBorder = Color("BrandTintBorder")
        static let cardFill = Color(.controlBackgroundColor)
        static let cardBorder = Color.primary.opacity(0.08)
        static let separator = Color.primary.opacity(0.08)
    }

    enum Motion {
        /// cubic-bezier(.23, 1, .32, 1)
        static func easeOut(_ duration: Double) -> Animation {
            .timingCurve(0.23, 1, 0.32, 1, duration: duration)
        }

        /// cubic-bezier(.77, 0, .175, 1)
        static func easeInOut(_ duration: Double) -> Animation {
            .timingCurve(0.77, 0, 0.175, 1, duration: duration)
        }

        /// Reduced motion keeps only a short opacity fade.
        static let reduced = Animation.linear(duration: 0.12)
    }
}
