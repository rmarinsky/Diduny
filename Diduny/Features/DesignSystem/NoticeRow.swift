import SwiftUI

/// "Sign in to record." with a primary button (design-spec 4.17): `tint` fill, radius 8,
/// padding 8 x 10, 10 apart. Spacing around it (14 below in Settings, none in the panel) is
/// the caller's.
struct NoticeRow: View {
    let text: LocalizedStringKey
    let buttonTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Palette.text)
            Spacer(minLength: 0)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(DS.Palette.accentFill)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(DS.Palette.tint, in: RoundedRectangle(cornerRadius: DS.Radius.notice, style: .continuous))
    }
}

/// Battery and Parakeet warnings (design-spec 7.1, 12.1.1): 11.5 `warn` text, line height 16.7,
/// wrapping, with an optional link in the same text flow (11.5 semibold `accentText`). No fill,
/// border or icon. The link is a text link, so it wraps with the sentence; the action runs
/// instead of opening a URL. It has no hover underline (a text run has no hover; deviation from
/// 4.19 for Roman). Accessibility sees the sentence and the link as two children, so each can
/// carry its identifier.
struct WarningLine: View {
    /// Already localized sentence.
    let message: String
    /// Already localized link, for example "Download 480 MB".
    var linkTitle: String?
    var action: () -> Void = {}
    /// For example `livePanel.batteryWarning` or `livePanel.parakeetMissing`.
    var id: String?
    /// For example `livePanel.useCloud` or `livePanel.downloadParakeet`.
    var linkID: String?

    private static let linkURL = URL(string: "diduny-warning-line://action")!

    var body: some View {
        Text(attributed)
            .font(DS.Font.meta)
            .foregroundStyle(DS.Palette.warn)
            .lineSpacing(DS.Font.LineSpacing.meta)
            .padding(.vertical, DS.Font.LineSpacing.meta / 2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tint(DS.Palette.accentText)
            .environment(\.openURL, OpenURLAction { url in
                guard url == Self.linkURL else { return .systemAction }
                action()
                return .handled
            })
            .accessibilityElement(children: .contain)
            .accessibilityChildren {
                Text(verbatim: message)
                    .accessibilityIdentifier(ifPresent: id)
                if let linkTitle {
                    Button(action: action) { Text(verbatim: linkTitle) }
                        .accessibilityIdentifier(ifPresent: linkID)
                }
            }
    }

    private var attributed: AttributedString {
        var text = AttributedString(message)
        guard let linkTitle else { return text }
        var link = AttributedString(linkTitle)
        link.link = Self.linkURL
        link.foregroundColor = DS.Palette.accentText
        link.font = DS.Font.meta.weight(.semibold)
        text += AttributedString(" ")
        text += link
        return text
    }
}
