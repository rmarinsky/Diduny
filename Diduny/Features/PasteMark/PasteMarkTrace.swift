import Foundation

/// DEV-only diagnostics for the logo landing: phases and geometry, never text.
/// `~/Library/Logs/Diduny DEV/pastemark.log`. Release builds compile this to nothing.
enum PasteMarkTrace {
    static func note(_ message: @autoclosure () -> String) {
        #if DEBUG
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message())\n"
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Diduny DEV")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("pastemark.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        #endif
    }
}
