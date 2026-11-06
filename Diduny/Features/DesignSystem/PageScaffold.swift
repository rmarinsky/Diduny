import SwiftUI

/// Pinned header + leading-aligned content column (inner 840, outer 888 with 24 insets).
/// Data screens use `scrolls: true` (default). Settings screens that host a native
/// grouped `Form` pass `scrolls: false` because the Form scrolls itself.
struct PageScaffold<Trailing: View, Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var scrolls = true
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var scrolled = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(DS.Palette.separator)
                .frame(height: 1)
                .opacity(scrolled ? 1 : 0)
            if scrolls {
                ScrollView {
                    column
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: PageScrollOffsetKey.self,
                                    value: proxy.frame(in: .named(PageScrollOffsetKey.space)).minY
                                )
                            }
                        )
                }
                .coordinateSpace(name: PageScrollOffsetKey.space)
                .onPreferenceChange(PageScrollOffsetKey.self) { offset in
                    let isScrolled = offset < -1
                    if isScrolled != scrolled { scrolled = isScrolled }
                }
            } else {
                content()
                    .frame(maxWidth: DS.Layout.outerColumnMaxWidth, maxHeight: .infinity, alignment: .topLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Page switch: new page only, no exit animation (so no added wait).
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 4)
        .onAppear {
            withAnimation(reduceMotion ? DS.Motion.reduced : DS.Motion.easeOut(0.14)) { appeared = true }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title)
                    .font(DS.Font.settingsTitle)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Font.body)
                        .lineSpacing(DS.Font.LineSpacing.lead)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: DS.Space.lg)
            trailing()
        }
        .padding(.horizontal, DS.Layout.pagePadding)
        .padding(.top, DS.Layout.pagePadding)
        // Lead to first block 14 (design-spec 3.5).
        .padding(.bottom, 14)
        .frame(maxWidth: DS.Layout.outerColumnMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var column: some View {
        content()
            .padding(.horizontal, DS.Layout.pagePadding)
            .padding(.bottom, DS.Layout.pagePadding)
            .frame(maxWidth: DS.Layout.outerColumnMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PageScaffold where Trailing == EmptyView {
    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        scrolls: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, scrolls: scrolls, trailing: { EmptyView() }, content: content)
    }
}

private struct PageScrollOffsetKey: PreferenceKey {
    static let space = "pageScroll"
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
