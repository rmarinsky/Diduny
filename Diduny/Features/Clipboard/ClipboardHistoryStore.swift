import CryptoKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// The clipboard history on disk, in `<Application Support>/<bundle id>/Clipboard`:
/// `index.jsonl` (one JSON `ClipboardEntry` per line, oldest first) and `Images/<id>.png` with
/// `Images/<id>.thumb.jpg`. Loading reads the index only. A new entry is appended; a delete or a
/// prune rewrites the index. Entry text is never logged.
@MainActor
@Observable
final class ClipboardHistoryStore {
    /// Longest text kept for one entry, in characters; a longer copy is cut to this.
    static let textCharacterCap = 100_000
    /// All image files together; over it, the oldest images go first.
    static let defaultImageBytesCap = 1_000_000_000
    /// Safety cap on the number of entries; over it, the oldest go first.
    static let entryCap = 20000
    /// Longest side of a thumbnail in pixels: the 132 x 78 pt frame at 2x, with room for scale-to-fill.
    static let thumbnailPixelSize = 320

    /// Newest first.
    private(set) var entries: [ClipboardEntry] = []

    @ObservationIgnored let directory: URL
    @ObservationIgnored let imageBytesCap: Int
    @ObservationIgnored private let fileManager = FileManager.default

    private var indexURL: URL { directory.appendingPathComponent("index.jsonl") }
    private var imagesURL: URL { directory.appendingPathComponent("Images") }

    static var defaultDirectory: URL {
        RecordingsLibraryStorage.defaultAppDirectory.appendingPathComponent("Clipboard")
    }

    init(directory: URL, imageBytesCap: Int = ClipboardHistoryStore.defaultImageBytesCap) {
        self.directory = directory
        self.imageBytesCap = imageBytesCap
        entries = Self.readIndex(at: directory.appendingPathComponent("index.jsonl"))
    }

    // MARK: - Add

    /// A text copied in an app. Nil when it repeats the newest text entry.
    @discardableResult
    func addCopiedText(_ rawText: String, app: ClipboardSourceApp, date: Date) -> ClipboardEntry? {
        let text = String(rawText.prefix(Self.textCharacterCap))
        let signature = Self.signature(Data(text.utf8))
        guard !repeatsNewest(kind: .text, signature: signature) else { return nil }
        return append(ClipboardEntry(
            id: UUID(), date: date, kind: .text, appName: app.name, bundleID: app.bundleID, text: text, signature: signature
        ))
    }

    /// Text that Diduny delivered. Every delivery is its own entry.
    @discardableResult
    func addDidunyText(_ rawText: String, origin: ClipboardEntry.Origin, app: ClipboardSourceApp, date: Date) -> ClipboardEntry? {
        let text = String(rawText.prefix(Self.textCharacterCap))
        return append(ClipboardEntry(
            id: UUID(), date: date, kind: .diduny, origin: origin, appName: app.name, bundleID: app.bundleID, text: text,
            signature: Self.signature(Data(text.utf8))
        ))
    }

    /// A copied image (PNG or TIFF data). Writes one PNG and one thumbnail. Nil when the data is not
    /// an image, a file cannot be written, or it repeats the newest image entry.
    @discardableResult
    func addImage(_ data: Data, app: ClipboardSourceApp, date: Date) -> ClipboardEntry? {
        let signature = Self.signature(data)
        guard !repeatsNewest(kind: .image, signature: signature),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let id = UUID()
        let imageFile = "\(id.uuidString).png"
        let thumbnailFile = "\(id.uuidString).thumb.jpg"
        let imageURL = imagesURL.appendingPathComponent(imageFile)
        do {
            try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
            if CGImageSourceGetType(source) as String? == UTType.png.identifier {
                try data.write(to: imageURL, options: .atomic)
            } else {
                guard Self.write(image, to: imageURL, type: .png) else { return nil }
            }
        } catch {
            Log.app.error("[Clipboard] Could not write an image: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailPixelSize,
        ]
        var entry = ClipboardEntry(
            id: id, date: date, kind: .image, appName: app.name, bundleID: app.bundleID, imageFile: imageFile,
            pixelWidth: image.width, pixelHeight: image.height, signature: signature
        )
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
           Self.write(thumbnail, to: imagesURL.appendingPathComponent(thumbnailFile), type: .jpeg)
        {
            entry.thumbnailFile = thumbnailFile
        }
        let size = (try? fileManager.attributesOfItem(atPath: imageURL.path))?[.size] as? Int
        entry.imageBytes = size ?? data.count
        return append(entry)
    }

    // MARK: - Read

    /// The full image of an entry; read only when the entry is copied back.
    func imageData(for entry: ClipboardEntry) -> Data? {
        entry.imageFile.flatMap { try? Data(contentsOf: imagesURL.appendingPathComponent($0)) }
    }

    func thumbnailURL(for entry: ClipboardEntry) -> URL? {
        entry.thumbnailFile.map { imagesURL.appendingPathComponent($0) }
    }

    func imageURL(for entry: ClipboardEntry) -> URL? {
        entry.imageFile.map { imagesURL.appendingPathComponent($0) }
    }

    // MARK: - Remove

    func delete(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        removeFiles(of: entries.remove(at: index))
        rewriteIndex()
    }

    /// Deletes every entry and the whole folder.
    func clear() {
        entries = []
        try? fileManager.removeItem(at: directory)
    }

    /// Removes entries older than the retention, then the oldest images over the size cap, then the
    /// oldest entries over the entry cap.
    func prune(retention: ClipboardRetention, now: Date) {
        var kept = entries
        var removed: [ClipboardEntry] = []
        if let interval = retention.interval {
            let cutoff = now.addingTimeInterval(-interval)
            removed += kept.filter { $0.date < cutoff }
            kept.removeAll { $0.date < cutoff }
        }
        var imageBytes = kept.reduce(0) { $0 + ($1.imageBytes ?? 0) }
        while imageBytes > imageBytesCap, let index = kept.lastIndex(where: { $0.kind == .image }) {
            imageBytes -= kept[index].imageBytes ?? 0
            removed.append(kept.remove(at: index))
        }
        if kept.count > Self.entryCap {
            removed += kept[Self.entryCap...]
            kept.removeLast(kept.count - Self.entryCap)
        }
        guard !removed.isEmpty else { return }
        entries = kept
        removed.forEach(removeFiles)
        rewriteIndex()
        Log.app.info("[Clipboard] Pruned \(removed.count) entries")
    }

    // MARK: - Files

    private func repeatsNewest(kind: ClipboardEntry.Kind, signature: String) -> Bool {
        guard let newest = entries.first else { return false }
        return newest.kind == kind && newest.signature == signature
    }

    private func append(_ entry: ClipboardEntry) -> ClipboardEntry? {
        guard var line = try? Self.encoder.encode(entry) else { return nil }
        line.append(0x0A)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: indexURL.path) {
                let handle = try FileHandle(forWritingTo: indexURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: indexURL, options: .atomic)
            }
        } catch {
            Log.app.error("[Clipboard] Could not write the index: \(error.localizedDescription, privacy: .public)")
            removeFiles(of: entry)
            return nil
        }
        entries.insert(entry, at: 0)
        return entry
    }

    private func rewriteIndex() {
        var data = Data()
        for entry in entries.reversed() {
            guard let line = try? Self.encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            Log.app.error("[Clipboard] Could not rewrite the index: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeFiles(of entry: ClipboardEntry) {
        for file in [entry.imageFile, entry.thumbnailFile].compactMap({ $0 }) {
            try? fileManager.removeItem(at: imagesURL.appendingPathComponent(file))
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func readIndex(at url: URL) -> [ClipboardEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A line that does not decode is skipped; the rest of the history stays.
        let entries = data.split(separator: 0x0A).compactMap { try? decoder.decode(ClipboardEntry.self, from: $0) }
        return entries.reversed()
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            return false
        }
        let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.8] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func signature(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
