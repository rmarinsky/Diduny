import Foundation

/// Tells apart browser data that macOS privacy protection blocks from data that does not exist.
public enum BrowserDataAccess {
    public enum Status: Equatable, Sendable {
        case readable
        case missing
        case blocked
    }

    /// Full Disk Access pane: the user can allow the app to read other apps' data there.
    public static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    public static func status(of file: URL) -> Status {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            try? handle.close()
            return .readable
        } catch let error as NSError {
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError)
                .flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
            if error.code == NSFileReadNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) {
                return .blocked
            }
            return .missing
        }
    }
}
