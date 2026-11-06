import SwiftUI

/// Settings > Providers comparison table (design-spec 3.6, 7.9; 03 1.2). A `Grid` with fixed column widths,
/// not `Table`: no header chrome, selection or zebra rows.
struct ProviderComparisonTable: View {
    let model: ProviderTableModel
    /// Opens a popup from a trigger: `name` is the `popup.<name>` suffix.
    let openPopup: (_ name: String, _ anchor: FloatingSurfaceAnchor, _ fromKeyboard: Bool) -> Void
    let openAccount: () -> Void
    let openLocalModels: () -> Void

    /// Column widths measured in the prototype at 711 pt (design-spec 3.6); the label column is flexible.
    static func width(of id: EngineID, withKey: Bool) -> CGFloat {
        switch (id, withKey) {
        case (.didunyCloud, true): 148.0
        case (.elevenLabs, _): 111.0
        case (.whisper, true): 154.5
        case (.parakeet, true): 113.3
        case (.appleSpeech, true): 81.0
        case (.didunyCloud, false): 149.9
        case (.whisper, false): 194.3
        case (.parakeet, false): 140.9
        case (.appleSpeech, false): 92.7
        }
    }

    private static let cellPadding: CGFloat = 8
    private static let groupRuleWidth: CGFloat = 2
    private static let groupPadding: CGFloat = 14

    private var firstLocalID: EngineID? { model.localColumns.first?.id }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            groupRow
            headerRow
            hairline
            ForEach(ProviderRowID.markRows, id: \.self) { row in
                GridRow {
                    labelCell(row.title)
                    ForEach(model.columns, id: \.id) { column in
                        cell(column) { markCell(row, column) }
                    }
                }
                hairline
            }
            GridRow {
                labelCell(ProviderRowID.languages.title)
                ForEach(model.columns, id: \.id) { column in
                    cell(column) { languagesButton(column) }
                }
            }
            hairline
            GridRow {
                labelCell(ProviderRowID.needs.title)
                ForEach(model.columns, id: \.id) { column in
                    cell(column) {
                        Text(verbatim: ProviderTableModel.needs(column.caps))
                            .font(DS.Font.callout)
                            .foregroundStyle(DS.Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(Text(verbatim: ProviderTableModel.accessibilityLabel(
                                column: column.name, row: .needs, value: ProviderTableModel.needs(column.caps)
                            )))
                            .accessibilityIdentifier("providers.cell.needs.\(column.id.rawValue)")
                    }
                }
            }
            hairline
            actionRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providers.table")
    }

    // MARK: Header

    private var groupRow: some View {
        GridRow {
            Color.clear.frame(height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
            groupLabel("Cloud providers", rule: false)
                .gridCellColumns(model.cloudColumns.count)
            groupLabel("Local models, on this Mac", rule: true)
                .gridCellColumns(model.localColumns.count)
        }
    }

    private func groupLabel(_ title: LocalizedStringKey, rule: Bool) -> some View {
        Text(title)
            .font(DS.Font.captionStrong)
            .foregroundStyle(DS.Palette.secondary)
            .padding(.leading, rule ? Self.groupRuleWidth + Self.groupPadding : Self.cellPadding)
            .padding([.top, .bottom, .trailing], Self.cellPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .leading) { if rule { groupRule } }
            .gridCellUnsizedAxes(.horizontal)
            .accessibilityAddTraits(.isHeader)
    }

    private var headerRow: some View {
        GridRow {
            // Bottom-aligned with the engine names (prototype).
            labelCell(String(localized: "In Diduny"), alignment: .bottomLeading)
            ForEach(model.columns, id: \.id) { column in
                cell(column, roundedTop: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: column.name)
                            .font(DS.Font.calloutStrong)
                            .foregroundStyle(DS.Palette.text)
                            .accessibilityAddTraits(.isHeader)
                        switch column.header {
                        case let .subline(text):
                            Text(verbatim: text)
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Palette.secondary)
                        case .yourKey:
                            PopupTrigger(name: "key", open: openPopup) { action in
                                InlineLink(title: "Your key", showsChevron: true, action: action)
                                    .font(DS.Font.caption)
                            }
                            .accessibilityHint(Text("Opens the ElevenLabs key"))
                            .accessibilityIdentifier("providers.yourKey")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("providers.header.\(column.id.rawValue)")
                }
            }
        }
    }

    // MARK: Cells

    private func markCell(_ row: ProviderRowID, _ column: ProviderColumn) -> some View {
        let parts = ProviderTableModel.marks(row, column.caps)
        let label = ProviderTableModel.accessibilityLabel(
            column: column.name, row: row, value: ProviderTableModel.accessibilityValue(parts)
        )
        return HStack(alignment: .top, spacing: 12) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                VStack(alignment: .leading, spacing: 2) {
                    CapabilityMark(kind: part.kind)
                    if part.kind == .byDiduny {
                        Text("By Diduny")
                            .font(DS.Font.captionStrong)
                            .foregroundStyle(DS.Palette.accentText)
                    }
                    if let subline = part.subline {
                        Text(verbatim: subline)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Palette.secondary)
                            .lineSpacing(DS.Font.LineSpacing.tableSubline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier("providers.cell.\(row.rawValue).\(column.id.rawValue)")
    }

    private func languagesButton(_ column: ProviderColumn) -> some View {
        let text = ProviderTableModel.languagesLabel(column.caps)
        return PopupTrigger(name: "languages.\(column.id.rawValue)", open: openPopup) { action in
            InlineLink(title: LocalizedStringKey(text), showsChevron: true, action: action)
                .font(DS.Font.callout)
        }
        .accessibilityLabel(Text(verbatim: ProviderTableModel.accessibilityLabel(column: column.name, row: .languages, value: text)))
        .accessibilityHint(Text("Opens the list"))
        .accessibilityIdentifier("providers.languages.\(column.id.rawValue)")
    }

    private var actionRow: some View {
        GridRow {
            Color.clear.frame(height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
            ForEach(model.cloudColumns, id: \.id) { column in
                cell(column, actionRow: true) {
                    if column.caps.traits.obtainedBy == .builtIn {
                        Button("Account and quota", action: openAccount)
                            .buttonStyle(.bordered)
                            .fixedSize()
                            .accessibilityIdentifier("providers.accountQuota")
                    }
                }
            }
            Button("Manage local models", action: openLocalModels)
                .buttonStyle(.bordered)
                .padding(.leading, Self.groupRuleWidth + Self.groupPadding)
                .padding(.top, 10)
                .padding([.bottom, .trailing], Self.cellPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .leading) { groupRule }
                .gridCellColumns(model.localColumns.count)
                .gridCellUnsizedAxes(.horizontal)
                .accessibilityIdentifier("providers.manageLocalModels")
        }
    }

    // MARK: Pieces

    /// One line (prototype 135.7): the label column takes the widest label.
    private func labelCell(_ text: String, alignment: Alignment = .topLeading) -> some View {
        Text(verbatim: text)
            .font(DS.Font.callout)
            .foregroundStyle(DS.Palette.text)
            .lineLimit(1)
            .fixedSize()
            .padding(Self.cellPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func cell(
        _ column: ProviderColumn,
        roundedTop: Bool = false,
        actionRow: Bool = false,
        @ViewBuilder content: () -> some View
    ) -> some View {
        let isFirstLocal = column.id == firstLocalID
        let isTinted = column.caps.traits.obtainedBy == .builtIn
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: roundedTop ? DS.Radius.cloudColumnHeader : 0,
            topTrailingRadius: roundedTop ? DS.Radius.cloudColumnHeader : 0,
            style: .continuous
        )
        return content()
            .padding(.leading, isFirstLocal ? Self.groupRuleWidth + Self.groupPadding : Self.cellPadding)
            .padding(.top, actionRow ? 10 : Self.cellPadding)
            .padding([.bottom, .trailing], Self.cellPadding)
            .frame(width: Self.width(of: column.id, withKey: model.hasKeyColumn), alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(isTinted ? DS.Palette.tint : Color.clear, in: shape)
            .overlay(alignment: .leading) { if isFirstLocal { groupRule } }
    }

    private var groupRule: some View {
        Rectangle().fill(DS.Palette.line).frame(width: Self.groupRuleWidth)
    }

    /// 1 pt `line` under a row; the tinted column keeps its fill through it.
    private var hairline: some View {
        Rectangle().fill(DS.Palette.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
    }
}

/// A trigger that opens a floating popup hung from itself.
private struct PopupTrigger<Label: View>: View {
    let name: String
    let open: (String, FloatingSurfaceAnchor, Bool) -> Void
    @ViewBuilder let label: (_ action: @escaping () -> Void) -> Label
    @State private var anchor = FloatingSurfaceAnchor()

    var body: some View {
        label { open(name, anchor, false) }
            .floatingSurfaceAnchor(anchor)
            .onKeyPress(keys: [.space, .return]) { _ in
                open(name, anchor, true)
                return .handled
            }
            .accessibilityAddTraits(.isButton)
    }
}

/// The three marks under the table (design-spec 7.9 item 6): 22 apart across, 6 down, wrapping.
struct ProviderLegend: View {
    var body: some View {
        LegendFlow(spacing: 22, lineSpacing: 6) {
            item(.yes, "The engine does it")
            item(.byDiduny, "By Diduny: the engine makes the text, Diduny translates it into any of 60 languages. Needs a Diduny account and uses its quota")
            item(.no, "Not available")
        }
        .font(DS.Font.callout)
        .foregroundStyle(DS.Palette.secondary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providers.legend")
    }

    private func item(_ kind: CapabilityMark.Kind, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            CapabilityMark(kind: kind, size: DS.Size.legendMark).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lays children left to right and wraps; a child wider than the row gets the full width.
private struct LegendFlow: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let frames = layout(width: proposal.width ?? .infinity, subviews: subviews)
        let width = frames.map(\.maxX).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for (frame, subview) in zip(layout(width: bounds.width, subviews: subviews), subviews) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func layout(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
