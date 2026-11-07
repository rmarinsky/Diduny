#if TEST_BUILD
    import AppKit
    import Carbon.HIToolbox
    import KeyboardShortcuts
    import os

    /// UI-test launch flags and seed (test-plan 2.2, implementation-plan WP-90). Compiled only in the
    /// Test configuration. Everything here seeds data or replaces an OS boundary (power, audio, paste,
    /// clock); the screens the tests see are the app's own.
    enum UITestHarness {
        static let seedEnvironment = "DIDUNY_UI_TEST_SEED"
        static let scriptEnvironment = "DIDUNY_UI_TEST_SCRIPT"
        static let fixtureArgument = "-uiStateFixture"

        /// The fixture's flags first, then the launch arguments, so a test's own flag wins (`value(of:)`
        /// reads the last match).
        static let arguments: [String] = {
            let raw = ProcessInfo.processInfo.arguments
            return (UITestStateFixture.named(in: raw)?.flags ?? []) + raw
        }()

        static func has(_ flag: String) -> Bool {
            arguments.contains(flag)
        }

        /// `--flag=value`; nil when absent.
        static func value(of flag: String) -> String? {
            let prefix = flag + "="
            return arguments.last { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }

        // MARK: Flags

        static var openTarget: String? { value(of: "--ui-testing-open") }
        static var isCommandPanelPinned: Bool { has("--ui-testing-command-panel-pinned") }
        static var stubsEngines: Bool { has("--ui-testing-stub-engines") }
        static var stubsPaste: Bool { has("--ui-testing-stub-paste") }
        static var showsProbe: Bool { has("--ui-testing-probe") }
        static var listensToBridge: Bool { has("--ui-testing-input-bridge") }
        static var quota: String? { value(of: "--ui-testing-quota") }
        static var transcriptEmitCount: Int? { value(of: "--ui-testing-transcript-emit").flatMap(Int.init) }

        /// `--ui-testing-audio-devices=Test Mic A,Test Mic B`: fake inputs; recording yields silence at level 0.5.
        static var fakeAudioDevices: [String]? {
            value(of: "--ui-testing-audio-devices").map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
        }

        static var usesFakeAudio: Bool { fakeAudioDevices != nil || stubsEngines }

        // MARK: Seed (DIDUNY_UI_TEST_SEED)

        /// Runs from `UITestLaunchState`, after the reset and before `SettingsStorage.shared` exists.
        /// Order: `legacy` (raw keys the migration reads), the migration, then `defaults`, `jobDefaults`
        /// and `shortcuts`. All of it goes to the persistent app domain, so values the UI changes are read
        /// back (a `-key value` argument would outrank them).
        static func applySeed(defaults: UserDefaults = .standard, didReset: Bool) {
            let seed = mergedSeed()
            if let legacy = seed["legacy"] as? [String: Any] {
                legacy.forEach { defaults.set($0.value, forKey: $0.key) }
            } else if didReset {
                // A fresh install's first launch runs the migration as a no-op that only stamps the
                // version. Do that here: launch arguments such as `-onboarding.completed` would
                // otherwise read as an existing install.
                defaults.set(SettingsMigration.currentSchemaVersion, forKey: SettingsMigration.schemaVersionKey)
            }
            guard seed["defaults"] != nil || seed["jobDefaults"] != nil || seed["shortcuts"] != nil else { return }
            // Let the migration run on the legacy keys before the seeded values land.
            let settings = SettingsStorage.shared
            (seed["defaults"] as? [String: Any])?.forEach { defaults.set($0.value, forKey: $0.key) }
            if let jobs = seed["jobDefaults"] as? [String: [String: String]] {
                for (job, value) in jobs {
                    guard let job = STTJob(rawValue: job), let provider = value["providerID"] else { continue }
                    settings.modeDefaults.setSelection(JobProviderSelection(providerID: provider, modelID: value["modelID"]), for: job)
                }
            }
            if let shortcuts = seed["shortcuts"] as? [String: String] {
                for (name, keys) in shortcuts {
                    KeyboardShortcuts.setShortcut(UITestKeys.shortcut(keys), for: KeyboardShortcuts.Name(name))
                }
            }
        }

        /// The fixture's seed with the variable's keys on top.
        static func mergedSeed() -> [String: Any] {
            var seed = UITestStateFixture.named(in: ProcessInfo.processInfo.arguments)?.seed ?? [:]
            if let json = ProcessInfo.processInfo.environment[seedEnvironment],
               let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                for (key, value) in object {
                    if let inner = value as? [String: Any], let existing = seed[key] as? [String: Any] {
                        seed[key] = existing.merging(inner) { _, new in new }
                    } else {
                        seed[key] = value
                    }
                }
            }
            return seed
        }

        // MARK: Fakes

        /// `--ui-testing-power=ac|battery|desktop`; nil leaves IOKit in charge.
        @MainActor static let powerSource: UITestPowerSource? = value(of: "--ui-testing-power").map(UITestPowerSource.init)

        /// `--ui-testing-fixed-clock=<ISO date>`: the monotonic clock stands still until bridge `clock.advance`.
        static let manualClock: UITestManualClock? = value(of: "--ui-testing-fixed-clock").map { _ in UITestManualClock() }

        /// What bridge `selection.set` put in place of the frontmost app's selection.
        static let stubbedSelection = OSAllocatedUnfairLock<String?>(initialState: nil)

        /// The fake input devices for `AudioDeviceManager`.
        static func fakeInputDevices() -> [AudioDevice]? {
            fakeAudioDevices.map { names in
                names.enumerated().map { index, name in
                    AudioDevice(
                        uid: name.lowercased().replacingOccurrences(of: " ", with: "-"),
                        id: AudioDeviceID(9000 + index),
                        name: name,
                        inputChannels: 1,
                        sampleRate: 48000,
                        transportType: .builtIn,
                        isDefault: index == 0
                    )
                }
            }
        }

        /// Ten seconds of 16 kHz mono silence as a WAV file: what the fake microphone and system audio record.
        static func silentWAV(seconds: Int = 10) -> Data {
            let sampleRate: UInt32 = 16000
            let dataSize = UInt32(seconds) * sampleRate * 2
            var data = Data()
            func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
            data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataSize)
            data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
            append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(sampleRate)
            append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
            data.append(contentsOf: Array("data".utf8)); append(dataSize)
            data.append(Data(count: Int(dataSize)))
            return data
        }
    }

    /// Fake power source; bridge `power` switches it.
    @MainActor
    final class UITestPowerSource: PowerSource {
        private(set) var current: PowerSourceKind
        private var observers: [@MainActor () -> Void] = []

        init(_ name: String) {
            current = Self.kind(name)
        }

        static func kind(_ name: String) -> PowerSourceKind {
            switch name {
            case "battery": .battery
            case "desktop": .none
            default: .ac
            }
        }

        func startObserving(_ onChange: @escaping @MainActor () -> Void) {
            observers.append(onChange)
        }

        func set(_ name: String) {
            current = Self.kind(name)
            observers.forEach { $0() }
        }
    }

    /// The in-app `ManualClock` behind `--ui-testing-fixed-clock` (test-plan 2.3).
    final class UITestManualClock: Sendable {
        private let seconds = OSAllocatedUnfairLock<TimeInterval>(initialState: 1000)

        var now: TimeInterval { seconds.withLock { $0 } }

        func advance(by delta: TimeInterval) {
            seconds.withLock { $0 += delta }
        }
    }

    /// "cmd+opt+k" as a `KeyboardShortcuts.Shortcut`, for the seed and bridge `hotkey`.
    enum UITestKeys {
        static func shortcut(_ text: String) -> KeyboardShortcuts.Shortcut? {
            var modifiers: NSEvent.ModifierFlags = []
            var keyName: String?
            for part in text.lowercased().split(separator: "+").map(String.init) {
                switch part {
                case "cmd", "command": modifiers.insert(.command)
                case "opt", "option", "alt": modifiers.insert(.option)
                case "ctrl", "control": modifiers.insert(.control)
                case "shift": modifiers.insert(.shift)
                default: keyName = part
                }
            }
            guard let keyName, let code = keyCodes[keyName] else { return nil }
            return KeyboardShortcuts.Shortcut(KeyboardShortcuts.Key(rawValue: code), modifiers: modifiers)
        }

        private static let keyCodes: [String: Int] = {
            let letters = [
                kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I,
                kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
                kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
            ]
            let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            var codes: [String: Int] = [
                "return": kVK_Return, "enter": kVK_Return, "escape": kVK_Escape, "esc": kVK_Escape, "space": kVK_Space,
                "tab": kVK_Tab, "comma": kVK_ANSI_Comma, ",": kVK_ANSI_Comma, "period": kVK_ANSI_Period, ".": kVK_ANSI_Period,
                "slash": kVK_ANSI_Slash, "/": kVK_ANSI_Slash,
            ]
            for (index, code) in letters.enumerated() {
                codes[String(UnicodeScalar(UInt8(97 + index)))] = code
            }
            for (index, code) in digits.enumerated() {
                codes[String(index)] = code
            }
            return codes
        }()
    }
#endif
