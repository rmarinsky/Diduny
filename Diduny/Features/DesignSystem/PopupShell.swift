import SwiftUI

extension DS {
    /// Popup shell metrics (design-spec 4.9).
    enum Popup {
        static let width: CGFloat = 460
        /// Standard body box: languages.
        static let bodyMaxHeight: CGFloat = 300
        static let bodyPadding: CGFloat = 10
        /// Change popup: a picker-menu list inside the box.
        static let listMaxHeight: CGFloat = 260
        static let listPadding: CGFloat = DS.Space.xs
        /// Header icon glyph (design-spec 9.1).
        static let iconGlyph: CGFloat = 15
        /// `xmark` in the close button (design-spec 4.7, 9.1).
        static let closeGlyph: CGFloat = 11
    }
}

/// Accessibility identifiers of a popup (test-plan 2.1).
enum PopupShellIdentifier {
    /// The popup window: `popup.languages.<engineId>`, `popup.key`, `popup.change.yourLanguages`, ...
    static func popup(_ name: String) -> String { "popup.\(name)" }
    static let close = "popup.close"
    static let search = "popup.search"
    static let body = "popup.body"
    static let footer = "popup.footer"
}

/// The popup shell (design-spec 4.9): the panel's look at 460 wide, on its own floating surface. Header with
/// icon tile, title, subtitle and close; optional search; optional body box; optional foot. Variants (language
/// columns, key rows, Change ticks) are the content.
struct PopupShell<Content: View, Footer: View>: View {
    private let icon: String
    private let title: String
    private let subtitle: String?
    private let search: Binding<String>?
    private let bodyStyle: PopupShellBody<Content>.Style
    private let accessibilityTitle: String?
    private let onClose: () -> Void
    private let content: () -> Content
    private let footer: () -> Footer

    /// - Parameters:
    ///   - icon: SF Symbol for the header tile (`globe`, `key`).
    ///   - accessibilityTitle: the popup's label ("ElevenLabs languages", "ElevenLabs key"); defaults to the title.
    ///   - content: the body; pass `EmptyView` for a popup with only a foot (Apple Speech).
    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        search: Binding<String>? = nil,
        bodyStyle: PopupShellBody<Content>.Style = .box,
        accessibilityTitle: String? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.search = search
        self.bodyStyle = bodyStyle
        self.accessibilityTitle = accessibilityTitle
        self.onClose = onClose
        self.content = content
        self.footer = footer
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.popup, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Panel.blockGap) {
            header
            if let search {
                // The presenter focuses it once the surface is key (`focusFirstTextField`).
                SurfaceSearchField(text: search, identifier: PopupShellIdentifier.search)
            }
            if Content.self != EmptyView.self {
                PopupShellBody(style: bodyStyle, content: content)
            }
            if Footer.self != EmptyView.self {
                footer()
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
                    .lineSpacing(DS.Font.LineSpacing.meta)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(PopupShellIdentifier.footer)
            }
        }
        // 12 padding inside the 1 pt border: content is 434 wide.
        .padding(DS.Panel.padding + DS.Panel.borderWidth)
        .frame(width: DS.Popup.width, alignment: .leading)
        .background(DS.Palette.panel, in: shape)
        .overlay(shape.strokeBorder(DS.Palette.line, lineWidth: DS.Panel.borderWidth))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(Text(verbatim: accessibilityTitle ?? title))
    }

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: DS.Popup.iconGlyph, weight: .medium))
                // White glyph on `accentFill` (design-spec 4.7).
                .foregroundStyle(.white)
                .frame(width: DS.Size.iconTile, height: DS.Size.iconTile)
                .background(
                    DS.Palette.accentFill,
                    in: RoundedRectangle(cornerRadius: DS.Radius.iconTile, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Palette.text)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.secondary)
                }
            }
            Spacer(minLength: 0)
            PopupCloseButton(action: onClose)
        }
    }
}

extension PopupShell where Footer == EmptyView {
    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        search: Binding<String>? = nil,
        bodyStyle: PopupShellBody<Content>.Style = .box,
        accessibilityTitle: String? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            icon: icon, title: title, subtitle: subtitle, search: search, bodyStyle: bodyStyle,
            accessibilityTitle: accessibilityTitle, onClose: onClose, content: content, footer: { EmptyView() }
        )
    }
}

/// The popup body (design-spec 4.9 item 3): a `box` that scrolls past its maximum height.
struct PopupShellBody<Content: View>: View {
    enum Style: Equatable {
        /// Fill `box`, radius 8, padding 10, up to 300 high (language list).
        case box
        /// Fill `box`, radius 8, padding 4, up to 260 high (Change popup's tick list).
        case list
        /// No box: rows sit on the shell (key popup).
        case plain
    }

    let style: Style
    @ViewBuilder let content: () -> Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.box, style: .continuous)
    }

    var body: some View {
        switch style {
        case .plain:
            content()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(PopupShellIdentifier.body)
        case .box, .list:
            ScrollView(.vertical) {
                content()
                    .padding(style == .box ? DS.Popup.bodyPadding : DS.Popup.listPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: style == .box ? DS.Popup.bodyMaxHeight : DS.Popup.listMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(DS.Palette.box, in: shape)
            .clipShape(shape)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(PopupShellIdentifier.body)
        }
    }
}

/// Close icon button: 26 x 26, radius 7, `chip` fill, `xmark` 11 semibold in `secondary`, `text` on hover.
private struct PopupCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: DS.Popup.closeGlyph, weight: .semibold))
                .foregroundStyle(isHovered ? DS.Palette.text : DS.Palette.secondary)
                .frame(width: DS.Size.iconButton, height: DS.Size.iconButton)
                .background(DS.Palette.chip, in: RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text("Close"))
        .accessibilityIdentifier(PopupShellIdentifier.close)
    }
}
