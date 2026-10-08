import SwiftUI

struct TranslationPairPickerPanelView: View {
    let model: TranslationPairPickerModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(Array(model.pairs.enumerated()), id: \.element.id) { index, pair in
                    row(index: index, pair: pair)
                }
            }
            .padding(6)

            Divider()

            HStack(spacing: 8) {
                hint("↑↓", "move")
                hint("1–\(min(model.pairs.count, 9))", "pick")
                hint("⏎", "start")
                hint("esc", "cancel")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: 260)
    }

    private func row(index: Int, pair: TranslationLanguagePair) -> some View {
        let isSelected = index == model.selectedIndex
        return Button {
            model.onCommit?(pair)
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .frame(width: 14)

                Text(pair.oneWayDisplayLabel)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer()

                if isSelected {
                    Image(systemName: "return")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color("BrandAccentDeep") : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                model.selectedIndex = index
            }
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                )
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}
