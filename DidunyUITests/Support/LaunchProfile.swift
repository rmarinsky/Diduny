import Foundation

/// Launch profiles of test-plan 2.2. Tests compose a profile; they do not build argument arrays by hand.
struct LaunchProfile {
    var flags: [String]
    /// Written to the persistent app domain through `DIDUNY_UI_TEST_SEED`, so UI writes are read back.
    var seed: [String: Any]

    /// `P-STD`.
    static var standard: LaunchProfile {
        LaunchProfile(
            flags: [
                "--ui-testing-signed-in", "--ui-testing-quota=available", "--ui-testing-stub-engines",
                "--ui-testing-stub-paste", "--ui-testing-fixed-clock=2026-11-06T10:00:00Z",
                "--ui-testing-command-panel-pinned", "--ui-testing-power=ac", "--ui-testing-parakeet=downloaded",
                "--ui-testing-whisper-models=ggml-large-v3-turbo:active", "--ui-testing-elevenlabs-key=absent",
                "--ui-testing-apple-speech=available", "--ui-testing-input-bridge", "--ui-testing-probe",
            ],
            seed: ["defaults": ["recordingFeedbackSurface": "compactPanel", "edgePanelDockEdge": "right"]]
        )
    }

    /// `P-BAT`.
    static var battery: LaunchProfile { standard.adding("--ui-testing-power=battery") }

    /// The flag wins over an earlier one with the same name (the app reads the last).
    func adding(_ flags: String...) -> LaunchProfile {
        LaunchProfile(flags: self.flags + flags, seed: seed)
    }

    /// Adds `defaults` keys to the seed.
    func seeding(defaults values: [String: Any]) -> LaunchProfile {
        var seed = seed
        seed["defaults"] = (seed["defaults"] as? [String: Any] ?? [:]).merging(values) { _, new in new }
        return LaunchProfile(flags: flags, seed: seed)
    }

    var seedJSON: String {
        let data = (try? JSONSerialization.data(withJSONObject: seed, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
