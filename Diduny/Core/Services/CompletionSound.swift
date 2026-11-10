import AppKit

/// The "done" sound. `NSSound.play()` waits on the output device; a stuck device held the main thread
/// for 10 s right after a paste, so the panel kept showing Finalizing. It never runs on the main thread.
enum CompletionSound {
    static func play(_ player: @escaping @Sendable () -> Void = { NSSound(named: .init("Funk"))?.play() }) {
        DispatchQueue.global(qos: .utility).async(execute: player)
    }
}
