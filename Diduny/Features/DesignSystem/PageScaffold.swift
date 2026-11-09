import SwiftUI

/// Receives a page's own content width, so a test can catch content wider than its column.
extension EnvironmentValues {
    @Entry var pageContentWidthProbe: ((CGFloat) -> Void)?
}

/// Pinned header + leading-aligned content column (inner up to `columnMaxWidth`, plus 24 insets).
/// Data screens use `scrolls: true` (default). Settings screens that host a native
/// grouped `Form` pass `scrolls: false` because the Form scrolls itself.
struct PageScaffold<Trailing: View, Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var scrolls = true
    /// Inner column cap: reading width for text pages, `DS.Layout.wideColumnMaxWidth` for table pages.
    var columnMaxWidth: CGFloat = DS.Layout.columnMaxWidth
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    private var outerColumnMaxWidth: CGFloat { columnMaxWidth + DS.Layout.pagePadding * 2 }

    static var titleTopPadding: CGFloat { 48 }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var scrolled = false
    @Environment(\.pageContentWidthProbe) private var contentWidthProbe

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
                fittedContent
                    .frame(minWidth: 0, maxWidth: outerColumnMaxWidth, maxHeight: .infinity, alignment: .topLeading)
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
        // The window draws under its 34 pt title bar (full-size content), so the title starts at 50
        // (design-spec 3.5): 48 of padding plus the title font's ~2 pt leading.
        .padding(.top, Self.titleTopPadding)
        // Lead to first block 14 (design-spec 3.5).
        .padding(.bottom, 14)
        .frame(maxWidth: outerColumnMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The column's width whatever the content asks for (`minWidth` 0): wider content cannot widen the page.
    private var fittedContent: some View {
        content()
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { contentWidthProbe?($0) }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var column: some View {
        fittedContent
            .padding(.horizontal, DS.Layout.pagePadding)
            .padding(.bottom, DS.Layout.pagePadding)
            .frame(minWidth: 0, maxWidth: outerColumnMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PageScaffold where Trailing == EmptyView {
    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        scrolls: Bool = true,
        columnMaxWidth: CGFloat = DS.Layout.columnMaxWidth,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title, subtitle: subtitle, scrolls: scrolls, columnMaxWidth: columnMaxWidth,
            trailing: { EmptyView() }, content: content
        )
    }
}

private struct PageScrollOffsetKey: PreferenceKey {
    static let space = "pageScroll"
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
