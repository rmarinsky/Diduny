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

    /// Nil when another process holds the lock for this folder.
    static func acquire(in directory: URL) -> AppInstanceLock? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(".lock").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            // A lock that cannot be created must not stop the app from starting.
            Log.app.error("Could not open the instance lock file: errno \(errno)")
            return AppInstanceLock(descriptor: open("/dev/null", O_RDONLY))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return AppInstanceLock(descriptor: descriptor)
    }
}
