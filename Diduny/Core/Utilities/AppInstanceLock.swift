import Foundation

/// An exclusive `flock` on `<appDir>/.lock`, held while the app runs. The system releases it when
/// the process ends, crash included, so a stale lock file never blocks a launch.
final class AppInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    enum Outcome {
        case acquired(AppInstanceLock)
        /// Another process of this build holds it.
        case heldElsewhere
        /// The lock file could not be opened; nothing is known about other copies.
        case unavailable(errno: Int32)
    }

    static func acquire(in directory: URL) -> Outcome {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(".lock").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return .unavailable(errno: errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return .heldElsewhere
        }
        return .acquired(AppInstanceLock(descriptor: descriptor))
    }
}
