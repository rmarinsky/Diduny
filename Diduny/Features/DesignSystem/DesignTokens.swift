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

        // Redesign radii (design-spec 3.1). Always with `style: .continuous`.
        static let panel: CGFloat = 12
        static let popup: CGFloat = 12
        static let iconTile: CGFloat = 8
        static let field: CGFloat = 8
        static let menu: CGFloat = 8
        static let menuRow: CGFloat = 5
        static let segmentTrack: CGFloat = 8
        static let segment: CGFloat = 6
        /// Transcript, calm and result boxes; popup body box.
        static let box: CGFloat = 8
        /// Copy, Stop and other panel buttons.
        static let panelButton: CGFloat = 8
        static let stopGlyph: CGFloat = 2
        static let keycap: CGFloat = 5
        static let iconButton: CGFloat = 7
        static let tile: CGFloat = 8
        static let headerLink: CGFloat = 6
        static let progressBar: CGFloat = 2
        static let notice: CGFloat = 8
        static let searchField: CGFloat = 6
        static let shortcutField: CGFloat = 6
        /// Expander and trash buttons.
        static let smallButton: CGFloat = 6
        /// Top corners of the Diduny Cloud column header.
        static let cloudColumnHeader: CGFloat = 8
        static let previewTile: CGFloat = 8
        static let previewDrawing: CGFloat = 6
        static let keyInput: CGFloat = 7
        static let sidebarFooter: CGFloat = 8
    }

    /// Control sizes (design-spec 3.2). Native controls (Settings buttons, switches,
    /// segmented pickers, pop-up pickers) keep their system size and are not listed.
    enum Size {
        static let fieldInline: CGFloat = 30
        static let fieldStacked: CGFloat = 42
        /// 2 inset + 30 segment + 2.
        static let segmentTrack: CGFloat = 34
        static let segment: CGFloat = 30
        static let segmentInset: CGFloat = 2
        /// Copy, Stop and other panel buttons.
        static let panelButton: CGFloat = 38
        /// Minimize and close, square.
        static let iconButton: CGFloat = 26
        /// Header icon tile, square.
        static let iconTile: CGFloat = 28
        /// Half-mark globe badge, square, offset right -4 and bottom -4.
        static let badge: CGFloat = 14
        static let badgeOffset: CGFloat = -4
        /// Waveform circle, square.
        static let waveformCircle: CGFloat = 38
        static let keycapHeight: CGFloat = 20
        static let statusDot: CGFloat = 7
        static let progressBar: CGFloat = 4
        static let menuRow: CGFloat = 25
        static let menuRowWithSubline: CGFloat = 38
        static let menuRowWithTwoLineSubline: CGFloat = 51
        static let menuGroupHeader: CGFloat = 23.4
        static let searchField: CGFloat = 27
        static let tileOneLine: CGFloat = 47
        static let tileTwoLines: CGFloat = 62
        static let headerLink: CGFloat = 23
        static let shortcutFieldHeight: CGFloat = 25
        static let shortcutFieldMinWidth: CGFloat = 58
        /// Expander button, square.
        static let expander: CGFloat = 26
        /// Trash button, square.
        static let trash: CGFloat = 24
        static let keyInput: CGFloat = 30
        static let sidebarFooter: CGFloat = 32
        static let micLevelWidth: CGFloat = 90
        static let micLevelHeight: CGFloat = 6
        static let mark: CGFloat = 20
        static let legendMark: CGFloat = 16
        /// Live control and meeting suggestion hit targets (pointer-only panel).
        static let panelHitTarget: CGFloat = 38
    }

    /// Floating panel metrics (design-spec 3.3). Height is the content's fitting height.
    enum Panel {
        static let width: CGFloat = 300
        static let padding: CGFloat = 12
        /// Vertical gap between blocks.
        static let blockGap: CGFloat = 10
        /// Drawn inside the shape (`strokeBorder`) in `Palette.line`.
        static let borderWidth: CGFloat = 1
        /// 300 minus 2 x 12 padding minus 2 x 1 border.
        static let contentWidth: CGFloat = width - padding * 2 - borderWidth * 2
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

        // Redesign type table (design-spec 2). Weights 400 and 600 only.
        // `body` (13) is the 13/400 row, `headline` (13/600) the panel title row,
        // `callout` (12) and `caption` (11) the 12/400 and 11/400 rows.

        /// 20/600: Settings page title.
        static let settingsTitle = SwiftUI.Font.system(size: 20, weight: .semibold)
        /// 15/600: Settings group heading.
        static let groupHeading = SwiftUI.Font.system(size: 15, weight: .semibold)
        /// 12.5/400: transcript, result, menu rows, popup lists, search fields.
        static let content = SwiftUI.Font.system(size: 12.5)
        /// 12.5/600: stacked field value, tile title.
        static let contentStrong = SwiftUI.Font.system(size: 12.5, weight: .semibold)
        /// 12/600: Settings buttons, status words, language buttons, table header.
        static let calloutStrong = SwiftUI.Font.system(size: 12, weight: .semibold)
        /// 12/600 rounded: shortcut field (D17).
        static let shortcutField = SwiftUI.Font.system(size: 12, weight: .semibold, design: .rounded)
        /// 11.5/400: caption line, warning, inline field label, row caption, popup foot.
        static let meta = SwiftUI.Font.system(size: 11.5)
        /// 11.5/600: mode segments.
        static let segment = SwiftUI.Font.system(size: 11.5, weight: .semibold)
        /// 11/600: speaker label, "By Diduny", table group headers, column headers.
        static let captionStrong = SwiftUI.Font.system(size: 11, weight: .semibold)
        /// 10.5/400: stacked field label.
        static let fieldLabel = SwiftUI.Font.system(size: 10.5)
        /// 10/400: cancel hint under Stop.
        static let footnote = SwiftUI.Font.system(size: 10)
        /// 10/600 rounded: Stop keycap (D17).
        static let keycap = SwiftUI.Font.system(size: 10, weight: .semibold, design: .rounded)

        /// `.lineSpacing` values: target line height minus SF Pro's natural one (design-spec 2).
        enum LineSpacing {
            /// Settings lead, 13 pt at line height 19.5.
            static let lead: CGFloat = 4
            /// Transcript and result boxes, 12.5 pt at 18.1.
            static let content: CGFloat = 3
            /// Popup lists, 12.5 pt at 21.25.
            static let popupList: CGFloat = 6
            /// Caption line and warning, 11.5 pt at 16.7.
            static let meta: CGFloat = 3
            /// Settings row caption, 11.5 pt at 16.1.
            static let rowCaption: CGFloat = 2.5
            /// Table sublines, 11 pt at 14.85.
            static let tableSubline: CGFloat = 1.5
        }
    }

    /// Colour roles. Redesign roles: docs/design/panels-and-capabilities-redesign/design-spec.md 1.1 and 1.2.
    /// The spec's `tint` role is `tintSoft`.
    enum Palette {
        static let accent = Color("BrandAccentDeep")
        static let tintSoft = Color("BrandTintSoft")
        static let tintBorder = Color("BrandTintBorder")
        static let cardFill = Color(.controlBackgroundColor)
        static let cardBorder = Color.primary.opacity(0.08)
        static let separator = Color.primary.opacity(0.08)

        /// Any fill with white text or a white glyph.
        static let accentFill = Color("BrandAccentFill")
        /// Any accent-coloured text or chevron.
        static let accentText = Color("BrandAccentText")
        static let window = Color("SurfaceWindow")
        static let sidebar = Color("SurfaceSidebar")
        /// Floating panel and every popup shell.
        static let panel = Color("SurfacePanel")
        /// Neutral control fill.
        static let chip = Color("SurfaceChip")
        /// Inset content inside a panel or popup.
        static let box = Color("SurfaceBox")
        /// Raised content: menus, tiles, shortcut field.
        static let card = Color("SurfaceCard")
        /// 1 pt borders and hairlines.
        static let line = Color("Hairline")
        static let text = Color("TextPrimary")
        static let secondary = Color("TextSecondary")
        static let ok = Color("StatusOk")
        /// Fill behind a white check (D2).
        static let okFill = Color("StatusOkFill")
        static let no = Color("StatusNo")
        static let warn = Color("StatusWarn")
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

        // Redesign motion table M1 to M18 (design-spec 5), as data.

        enum Curve: Equatable {
            /// `easeOut(_:)`
            case easeOut
            /// `easeInOut(_:)`
            case easeInOut
            case linear
            /// No animation: the change applies at once.
            case instant
            /// The system control animates itself.
            case native
        }

        /// What happens when Reduce Motion is on.
        enum ReducedMotion: Equatable {
            /// Same animation as without Reduce Motion.
            case same
            /// Opacity only, with `reduced` (120 ms).
            case opacityFade
            /// The change applies at once.
            case instant
            /// The effect is not shown at all.
            case skip
            /// The system control decides.
            case native
        }

        struct Token: Equatable {
            /// Seconds; 0 for `.instant` and `.native`.
            let duration: Double
            let curve: Curve
            let reducedMotion: ReducedMotion
        }

        /// Command panel content swap: offset `slideOffset` from the docked edge plus opacity.
        static let m1ContentSwap = Token(duration: 0.22, curve: .easeOut, reducedMotion: .opacityFade)
        /// Panel window height during M1; the docked edge stays fixed.
        static let m2PanelHeight = Token(duration: 0.22, curve: .easeInOut, reducedMotion: .instant)
        /// Not a swap: Stop to progress row, home redraw.
        static let m3InPlaceChange = Token(duration: 0, curve: .instant, reducedMotion: .instant)
        /// Picker menu open: opacity plus scale from `popScale`, anchored at the trigger corner.
        static let m4MenuOpen = Token(duration: 0.18, curve: .easeOut, reducedMotion: .opacityFade)
        static let m5MenuClose = Token(duration: 0, curve: .instant, reducedMotion: .instant)
        /// Popup open: opacity plus scale from `popScale`, anchored at the trigger centre.
        static let m6PopupOpen = Token(duration: 0.20, curve: .easeOut, reducedMotion: .opacityFade)
        /// Popup close: opacity plus scale to `popScale`, then remove (D13).
        static let m7PopupClose = Token(duration: 0.15, curve: .easeOut, reducedMotion: .opacityFade)
        /// Success pulse: scale 1 to `pulseScale` to 1, two halves of 0.2 s.
        static let m8SuccessPulse = Token(duration: 0.40, curve: .easeOut, reducedMotion: .skip)
        /// Mode segment fill and text colour cross-fade.
        static let m9SegmentSelection = Token(duration: 0.18, curve: .easeOut, reducedMotion: .instant)
        static let m10Switch = Token(duration: 0, curve: .native, reducedMotion: .native)
        /// Press scale `pressScale` (fields `fieldPressScale`).
        static let m11Press = Token(duration: 0.12, curve: .easeOut, reducedMotion: .skip)
        /// Tile hover fill `card` to `tint`.
        static let m12TileHover = Token(duration: 0.15, curve: .easeOut, reducedMotion: .same)
        /// Field hover border, link underline, menu row hover.
        static let m13Hover = Token(duration: 0, curve: .instant, reducedMotion: .instant)
        /// Expander chevron rotation 0 to 180 degrees.
        static let m14Expander = Token(duration: 0.18, curve: .easeOut, reducedMotion: .instant)
        /// Level meter bars follow the real level.
        static let m15LevelMeter = Token(duration: 0.10, curve: .easeOut, reducedMotion: .instant)
        /// Progress bar width, per update.
        static let m16Progress = Token(duration: 0.20, curve: .linear, reducedMotion: .same)
        /// Copy to Copied label.
        static let m17CopyLabel = Token(duration: 0.16, curve: .easeOut, reducedMotion: .instant)
        /// Local models row states and key popup states.
        static let m18RowStates = Token(duration: 0, curve: .instant, reducedMotion: .instant)

        /// M1 offset from the docked edge, points.
        static let slideOffset: CGFloat = 16
        /// M4, M6, M7 start or end scale.
        static let popScale: CGFloat = 0.95
        /// M8 peak scale.
        static let pulseScale: CGFloat = 1.15
        /// M11 press scale for buttons, segments, tiles.
        static let pressScale: CGFloat = 0.97
        /// M11 press scale for picker fields.
        static let fieldPressScale: CGFloat = 0.99
    }
}
