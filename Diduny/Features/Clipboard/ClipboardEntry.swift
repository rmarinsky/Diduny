import Foundation

/// One record of the clipboard history index. Image bytes are never here; `imageFile` and
/// `thumbnailFile` name files in the store's `Images` folder.
struct ClipboardEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        /// Text copied in an app.
        case text
        /// An image copied in an app, or a screenshot.
        case image
        /// Text that Diduny itself delivered.
        case diduny
        /// Files copied in Finder or another app. Only their paths are kept, never their content.
        case files
    }

    /// What Diduny did with the text of a `.diduny` entry.
    enum Origin: String, Codable {
        case dictated
        case translated
    }

    let id: UUID
    let date: Date
    let kind: Kind
    var origin: Origin?
    /// The frontmost app at capture time; for a Diduny entry, the app that received the paste.
    var appName: String?
    var bundleID: String?
    /// The full plain text, up to `ClipboardHistoryStore.textCharacterCap` characters.
    var text: String?
    /// Absolute paths of a `.files` entry, in copy order.
    var filePaths: [String]?
    var imageFile: String?
    var thumbnailFile: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// Size of the image file, for the size cap.
    var imageBytes: Int?
    /// SHA-256 of the copied text, image data or file paths; finds a repeated copy.
    var signature: String

    var fileNames: [String] { (filePaths ?? []).map { URL(fileURLWithPath: $0).lastPathComponent } }
}

/// The frontmost app when something was copied or pasted.
struct ClipboardSourceApp: Equatable {
    var name: String?
    var bundleID: String?

    static let unknown = ClipboardSourceApp(name: nil, bundleID: nil)
}
