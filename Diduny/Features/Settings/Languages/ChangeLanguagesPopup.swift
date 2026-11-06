import SwiftUI

/// The Change popup (design-spec 4.9 Change variant, 7.13): 460 wide, globe header, search, tick list with
/// "Chosen" then "All languages". Each tick is written at once (05 §2.3 proposal).
struct ChangeLanguagesPopup: View {
    let list: LanguageChangeList
    let model: LanguagesSettingsModel
    let onClose: () -> Void

    @State private var query = ""

    private var rows: ChangeLanguagesRows {
        ChangeLanguagesRows(
            chosen: model.chosen(list), all: LanguagesSettingsModel.allCodes, query: query,
            name: LanguagesSettingsModel.name
        )
    }

    var body: some View {
        PopupShell(
            icon: "globe", title: list.title, subtitle: list.subtitle, search: $query, bodyStyle: .list,
            onClose: onClose
        ) {
            let rows = rows
            VStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    PickerMenuGroupHeader(title: PickerMenuModel.nothingFoundTitle, identifier: "popup.empty")
                }
                if !rows.chosen.isEmpty {
                    PickerMenuGroupHeader(title: String(localized: "Chosen"), identifier: "popup.group.chosen")
                    ForEach(rows.chosen, id: \.self) { tickRow($0, isChosen: true) }
                }
                if !rows.rest.isEmpty {
                    PickerMenuGroupHeader(title: String(localized: "All languages"), identifier: "popup.group.all")
                    ForEach(rows.rest, id: \.self) { tickRow($0, isChosen: false) }
                }
            }
        }
    }

    private func tickRow(_ code: String, isChosen: Bool) -> some View {
        ChangeTickRow(
            name: LanguagesSettingsModel.name(code), code: code, isChosen: isChosen,
            isEnabled: model.canToggle(code, in: list)
        ) { model.toggle(code, in: list) }
    }
}

/// A 4.2 menu row as a checkbox: 14 pt tick column (`checkmark` 12 `accentText` when chosen), the name; chosen
/// rows `accentText` semibold.
private struct ChangeTickRow: View {
    let name: String
    let code: String
    let isChosen: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.menuRow, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Palette.accentText)
                    .opacity(isChosen ? 1 : 0)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(verbatim: name)
                    .font(isChosen ? DS.Font.contentStrong : DS.Font.content)
                    .foregroundStyle(isChosen ? DS.Palette.accentText : DS.Palette.text)
            }
            .padding(.vertical, DS.Menu.rowVerticalPadding)
            .padding(.horizontal, DS.Menu.rowHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered && isEnabled ? DS.Palette.chip : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text(verbatim: isChosen ? "1" : "0"))
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("popup.tick.\(code)")
    }
}
