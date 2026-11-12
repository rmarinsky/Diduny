import Foundation

/// Keeps the Mac from idle sleep while Diduny transcribes or writes notes, so a long job
/// is not frozen halfway when the person walks away. The display may still sleep.
struct ProcessingActivity {
    static let options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
    static let live = ProcessingActivity(
        begin: { ProcessInfo.processInfo.beginActivity(options: options, reason: $0) },
        end: { ProcessInfo.processInfo.endActivity($0) }
    )

    let begin: (String) -> NSObjectProtocol
    let end: (NSObjectProtocol) -> Void

    func run<T>(_ reason: String, _ work: () async throws -> T) async rethrows -> T {
        let token = begin(reason)
        defer { end(token) }
        return try await work()
    }
}
