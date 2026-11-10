import Foundation

/// The language to force on an on-device engine (Parakeet, Whisper, Apple).
/// Parakeet's language is a script filter and Whisper forces it, so a wrong guess garbles the text:
/// force one only when the person's languages resolve to exactly one, otherwise let the engine detect.
/// Cloud engines don't use this; they take the whole hint list as a soft hint.
enum OnDeviceLanguage {
    /// An explicit per-run choice wins; else the single hint; else nil (detect).
    static func resolve(hints: [String], explicit: String? = nil) -> String? {
        if let explicit, !explicit.isEmpty, explicit != BenchmarkRun.autoLanguage { return explicit }
        let codes = Array(Set(hints.filter { !$0.isEmpty && $0 != BenchmarkRun.autoLanguage }))
        return codes.count == 1 ? codes[0] : nil
    }

    /// The value for `BenchmarkEngine.transcribe(_:language:)`, where "auto" means detect.
    static func engineArgument(hints: [String], explicit: String? = nil) -> String {
        resolve(hints: hints, explicit: explicit) ?? BenchmarkRun.autoLanguage
    }
}
