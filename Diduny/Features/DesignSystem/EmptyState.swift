import SwiftUI

/// 48 pt tint circle + headline + callout + optional action.
/// `compact` is the variant used inside a card or form: smaller circle, leading-aligned, no vertical centring.
struct EmptyState<Action: View>: View {
    let icon: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    var compact = false
    @ViewBuilder var action: () -> Action

    var body: some View {
        if compact {
            HStack(alignment: .top, spacing: DS.Space.md) {
                badge(size: 32)
                text(alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        } else {
            VStack(spacing: DS.Space.md) {
                Spacer(minLength: DS.Space.xl)
                badge(size: 48)
                text(alignment: .center)
                Spacer(minLength: DS.Space.xl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
        }
    }

    private func badge(size: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(DS.Palette.accent)
            .frame(width: size, height: size)
            .background(DS.Palette.tintSoft, in: Circle())
            .overlay(Circle().strokeBorder(DS.Palette.tintBorder, lineWidth: 1))
            .accessibilityHidden(true)
    }

    private func text(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: DS.Space.xs) {
            Text(title).font(DS.Font.headline)
            if let message {
                Text(message)
                    .font(DS.Font.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action().padding(.top, DS.Space.xs)
        }
    }
}

extension EmptyState where Action == EmptyView {
    init(icon: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil, compact: Bool = false) {
        self.init(icon: icon, title: title, message: message, compact: compact, action: { EmptyView() })
    }
}
