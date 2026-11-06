import SwiftUI

/// The visible shortcut field (design-spec 4.14): the whole shortcut as one string ("⌥⌘D"),
/// 12 semibold rounded (D17), `card` fill, 1 pt `line`, 25 high, at least 58 wide. Visual layer
/// only: the screen lays the invisible recorder (ADR-0012 D8, WP-15) over it and passes
/// `isRecording`. `.disabled(true)` draws it at 0.6 (Open Settings ⌘,).
struct ShortcutField: View {
    /// Display string; nil draws an empty field.
    let shortcut: String?
    /// Already localized row label, for "<row label> shortcut".
    let rowLabel: String
    var isRecording = false
    /// The row's switch is off: field at 0.45.
    var isOff = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if isRecording {
                Text("Press keys...")
            } else {
                Text(verbatim: shortcut ?? "")
            }
        }
        .font(DS.Font.shortcutField)
        .foregroundStyle(isRecording ? DS.Palette.accentText : DS.Palette.text)
        .lineLimit(1)
        // CSS padding 4 x 8 plus the 1 pt border, which `strokeBorder` draws inside.
        .padding(.horizontal, 9)
        .frame(minWidth: DS.Size.shortcutFieldMinWidth)
        .frame(height: DS.Size.shortcutFieldHeight)
        .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: DS.Radius.shortcutField, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.shortcutField, style: .continuous)
                .strokeBorder(isRecording ? DS.Palette.accent : DS.Palette.line, lineWidth: 1)
        )
        .opacity(isOff ? 0.45 : isEnabled ? 1 : 0.6)
        .accessibilityElement()
        .accessibilityLabel(Text("\(rowLabel) shortcut"))
        .accessibilityValue(isRecording ? Text("Press keys...") : Text(verbatim: Self.spokenName(shortcut ?? "", locale: locale)))
    }

    /// The shortcut as VoiceOver should say it (spec 4.14): "⌥⌘D" is "Option Command D".
    /// Leading modifier glyphs are named one by one; the rest is the key ("D", "Space", "Esc").
    static func spokenName(_ shortcut: String, locale: Locale) -> String {
        func localized(_ key: String.LocalizationValue) -> String {
            String(localized: LocalizedStringResource(key, locale: locale))
        }
        var words: [String] = []
        var rest = Substring(shortcut)
        while let first = rest.first, let name = modifierNames[first] {
            words.append(localized(name))
            rest = rest.dropFirst()
        }
        let key = String(rest)
        if let name = keyNames[key] {
            words.append(localized(name))
        } else if !key.isEmpty {
            words.append(key.count == 1 ? key.uppercased() : key)
        }
        return words.joined(separator: " ")
    }

    private static let modifierNames: [Character: String.LocalizationValue] = [
        "⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command", "⇪": "Caps Lock",
    ]

    private static let keyNames: [String: String.LocalizationValue] = [
        "↩": "Return", "⎋": "Escape", "Esc": "Escape", "⇥": "Tab", "⌫": "Delete key",
        "Space": "Space", " ": "Space", "←": "Left Arrow", "→": "Right Arrow", "↑": "Up Arrow", "↓": "Down Arrow",
    ]
}

/// 1× 2× 3× (4.14 item 2): native small segmented picker, label "Press count".
struct ShortcutPressCountPicker: View {
    @Binding var selection: Int
    var isOff = false

    var body: some View {
        Picker("Press count", selection: $selection) {
            ForEach(1 ... 3, id: \.self) { count in
                Text(verbatim: "\(count)×").tag(count)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        // White on `AccentColor` dark is 2.96:1; filled controls use `accentFill` (spec 1.1).
        .tint(DS.Palette.accentFill)
        .labelsHidden()
        .fixedSize()
        .opacity(isOff ? 0.45 : 1)
    }
}
