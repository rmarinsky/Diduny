import SwiftUI

/// Radius 12, red tint 7% + 22% border, headline + body, actions trailing.
/// `message` is a `Text` so callers can pass runtime error strings with `Text(verbatim:)`.
struct Banner<Actions: View>: View {
    var headline: LocalizedStringKey?
    let message: Text
    @ViewBuilder var actions: () -> Actions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if let headline { Text(headline).font(DS.Font.headline) }
                message
                    .font(DS.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: DS.Space.md)
            HStack(spacing: DS.Space.sm) { actions() }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(Color.red.opacity(0.22), lineWidth: 1)
        )
        // Appears with opacity + 4 pt rise; exit is instant.
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : -4)
        .onAppear { withAnimation(reduceMotion ? DS.Motion.reduced : DS.Motion.easeOut(0.16)) { appeared = true } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}
