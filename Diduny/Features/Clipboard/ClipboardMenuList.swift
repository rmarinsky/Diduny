import AppKit
import SwiftUI

/// What one row of the menu bar Clipboard list says.
@MainActor
struct ClipboardMenuRow: Equatable {
    /// Longest first line, in characters; a longer one is cut with "…".
    static let titleLimit = 50

    let title: String
    let subtitle: String
    /// False for a files entry whose files are all gone: the row is disabled.
    let isAvailable: Bool

    init(
        _ entry: ClipboardEntry, now: Date = Date(), calendar: Calendar = .current,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) {
        title = Self.title(for: entry)
        isAvailable = entry.kind != .files || (entry.filePaths ?? []).contains(where: fileExists)
        subtitle = isAvailable
            ? ClipboardPageModel.caption(for: entry) + " · " + Self.time(entry.date, now: now, calendar: calendar)
            : String(localized: "Moved or deleted")
    }

    /// The first line that has text, whitespace collapsed to single spaces, cut to `titleLimit`.
    static func title(for entry: ClipboardEntry) -> String {
        let line: String
        if entry.kind == .text || entry.kind == .diduny {
            let firstLine = (entry.text ?? "").prefix(400).split(whereSeparator: \.isNewline)
                .first { !$0.allSatisfy(\.isWhitespace) } ?? ""
            line = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        } else {
            line = ClipboardPageModel.title(for: entry)
        }
        return line.count > titleLimit ? String(line.prefix(titleLimit - 1)) + "…" : line
    }

    /// The time today; on an earlier day the numeric day and month first, in the system's format ("19.11 21:54").
    static func time(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar))
        guard !calendar.isDate(date, inSameDayAs: now) else { return time }
        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.setLocalizedDateFormatFromTemplate("dMM")
        return day.string(from: date) + " " + time
    }
}

/// The scrolling list inside the Clipboard submenu. A plain `NSMenu` cannot limit its height, so the
/// list is one menu item with a view: fixed-height rows, `visibleRows` of them in sight.
struct ClipboardMenuList: View {
    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 40

    let entries: [ClipboardEntry]
    let thumbnailURL: (ClipboardEntry) -> URL?
    let onPick: (ClipboardEntry) -> Void

    static func size(count: Int, visibleRows: Int) -> CGSize {
        CGSize(width: width, height: CGFloat(min(count, max(1, visibleRows))) * rowHeight)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    ClipboardMenuRowView(entry: entry, thumbnailURL: thumbnailURL(entry)) { onPick(entry) }
                }
            }
            .padding(.horizontal, DS.Space.xs + 1)
        }
    }
}

private struct ClipboardMenuRowView: View {
    let entry: ClipboardEntry
    let thumbnailURL: URL?
    let onPick: () -> Void

    private let row: ClipboardMenuRow
    @State private var isHovered = false

    init(entry: ClipboardEntry, thumbnailURL: URL?, onPick: @escaping () -> Void) {
        self.entry = entry
        self.thumbnailURL = thumbnailURL
        self.onPick = onPick
        row = ClipboardMenuRow(entry)
    }

    private var isHighlighted: Bool { isHovered && row.isAvailable }

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: DS.Space.sm) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.title)
                        .font(DS.Font.body)
                        .foregroundStyle(isHighlighted ? Color.white : row.isAvailable ? DS.Palette.text : DS.Palette.secondary)
                        .lineLimit(1)
                    Text(verbatim: row.subtitle)
                        .font(DS.Font.caption)
                        .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : DS.Palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(height: ClipboardMenuList.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.menuRow, style: .continuous)
                    .fill(isHighlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.isAvailable)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(row.subtitle)
    }

    @ViewBuilder private var leading: some View {
        switch entry.kind {
        case .image:
            ClipboardMenuThumbnail(url: thumbnailURL)
        case .files:
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.filePaths?.first ?? ""))
                .resizable()
                .frame(width: 24, height: 24)
                .frame(width: 36)
                .opacity(row.isAvailable ? 1 : 0.4)
        case .text, .diduny:
            // Same column as thumbnails and file icons, so every title starts at one edge.
            Color.clear.frame(width: 36, height: 24)
        }
    }
}

/// 36 x 24: the small file made at capture; the full image is never decoded here.
private struct ClipboardMenuThumbnail: View {
    let url: URL?

    @State private var image: NSImage?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.previewDrawing / 2, style: .continuous)
    }

    var body: some View {
        ZStack {
            DS.Palette.box
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 36, height: 24)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DS.Palette.line, lineWidth: 1))
        .task(id: url) {
            guard let url else { return }
            image = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
        }
    }
}
