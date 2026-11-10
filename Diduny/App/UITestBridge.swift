#if TEST_BUILD
    import AppKit
    import KeyboardShortcuts
    import os

    /// Test bridge (test-plan 2.7, `--ui-testing-input-bridge`): XCUITest posts a distributed
    /// notification whose `object` is JSON (`cmd`, `seq`, arguments). Only the OS event delivery is
    /// replaced; press counting, routing and the panels stay real.
    @MainActor
    final class UITestBridge {
        static let shared = UITestBridge()
        static let notificationName = Notification.Name("ua.com.rmarinsky.diduny.test.bridge")

        private(set) var seq = 0
        private(set) var lastAction = ""
        private var observer: NSObjectProtocol?

        func start() {
            guard observer == nil else { return }
            observer = DistributedNotificationCenter.default().addObserver(
                forName: Self.notificationName, object: nil, queue: .main
            ) { note in
                let json = note.object as? String
                MainActor.assumeIsolated { UITestBridge.shared.handle(json) }
            }
        }

        private func handle(_ json: String?) {
            guard let data = json?.data(using: .utf8),
                  let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let cmd = command["cmd"] as? String
            else { return }
            lastAction = perform(cmd, command)
            seq = command["seq"] as? Int ?? seq + 1
            UITestProbe.shared.refresh()
        }

        /// Returns the probe's `lastAction`.
        private func perform(_ cmd: String, _ args: [String: Any]) -> String {
            func number(_ key: String) -> Double { (args[key] as? NSNumber)?.doubleValue ?? 0 }
            switch cmd {
            case "hotkey":
                let keys = args["keys"] as? String ?? ""
                return KeyboardShortcutsRegistrar.shared.fireForUITesting(keys: keys) ? "hotkey" : "hotkey.unmatched"
            case "flags":
                UITestKeySources.send(flagsFor: UInt16(number("keyCode")), down: args["down"] as? Bool ?? false, at: number("t"))
            case "key":
                UITestKeySources.send(.keyDown(
                    keyCode: UInt16(number("keyCode")), modifiersRawValue: UInt(number("modifiers")),
                    isRepeat: false, timestamp: number("t")
                ))
            case "clock.advance":
                UITestHarness.manualClock?.advance(by: number("seconds"))
                let store = DictationOverlayController.shared.store
                if let ended = store.endedAt { store.endedAt = ended.addingTimeInterval(number("seconds")) }
            case "meeting.useCloud":
                // The battery link's action: its sentence link has no frame of its own for a synthetic click.
                DictationOverlayController.shared.store.pickMeetingSegment(.cloud)
            case "power":
                UITestHarness.powerSource?.set(args["source"] as? String ?? "ac")
            case "meeting.detected":
                let client = MeetingClient(rawValue: args["app"] as? String ?? "") ?? .zoom
                EdgeCommandPanelController.shared.showMeetingSuggestion(DetectedMeeting(id: UUID(), client: client))
            case "transcript.emit":
                UITestScript.emit(count: Int(number("count")))
            case "selection.set":
                UITestHarness.stubbedSelection.withLock { $0 = args["text"] as? String }
            case "download.advance":
                UITestFakeParakeetDownload.shared.advance(to: number("percent") / 100)
            case "download.fail":
                UITestFakeParakeetDownload.shared.fail()
            default:
                // `auth.set`: not built yet (see role notes).
                return "unsupported.\(cmd)"
            }
            return cmd
        }
    }

    /// The live `NSEventKeySource`s, so bridge `flags` and `key` reach them as the OS would.
    enum UITestKeySources {
        private struct Entry {
            weak var source: NSEventKeySource?
            let mask: NSEvent.EventTypeMask
            let handler: (KeyEvent) -> Void
        }

        private static let entries = OSAllocatedUnfairLock<[ObjectIdentifier: Entry]>(initialState: [:])
        /// Modifier key codes held down through the bridge.
        private static let heldCodes = OSAllocatedUnfairLock<Set<UInt16>>(initialState: [])

        static func register(_ source: NSEventKeySource, mask: NSEvent.EventTypeMask, handler: @escaping (KeyEvent) -> Void) {
            entries.withLock { $0[ObjectIdentifier(source)] = Entry(source: source, mask: mask, handler: handler) }
        }

        static func unregister(_ source: NSEventKeySource) {
            _ = entries.withLock { $0.removeValue(forKey: ObjectIdentifier(source)) }
        }

        static func send(_ event: KeyEvent) {
            let type: NSEvent.EventTypeMask = if case .flagsChanged = event { .flagsChanged } else { .keyDown }
            let handlers = entries.withLock { $0.values.filter { $0.source != nil && $0.mask.contains(type) }.map(\.handler) }
            handlers.forEach { $0(event) }
        }

        /// Key code to (modifier flag, device mask bit), as `PushToTalkService` matches them.
        private static let modifierBits: [UInt16: (NSEvent.ModifierFlags, UInt)] = [
            54: (.command, 0x10), 55: (.command, 0x08), 56: (.shift, 0x02), 60: (.shift, 0x04),
            58: (.option, 0x20), 61: (.option, 0x40), 59: (.control, 0x01), 62: (.control, 0x2000),
            57: (.capsLock, 0),
        ]

        static func send(flagsFor keyCode: UInt16, down: Bool, at time: TimeInterval) {
            guard modifierBits[keyCode] != nil else { return }
            // Key codes held down, so releasing one side keeps the other side's flag.
            let downCodes = heldCodes.withLock { codes -> Set<UInt16> in
                if down { codes.insert(keyCode) } else { codes.remove(keyCode) }
                return codes
            }
            var flags: NSEvent.ModifierFlags = []
            var device: UInt = 0
            for code in downCodes {
                guard let (flag, bit) = modifierBits[code] else { continue }
                flags.insert(flag)
                device |= bit
            }
            send(.flagsChanged(keyCode: keyCode, flagsRawValue: flags.rawValue | device, timestamp: time))
        }
    }

    /// Shortcut capture state for the probe's `capture` key (WP-90): which row records and why it stopped.
    @MainActor
    enum UITestCaptureTrace {
        static var recordingRow: String?
        static var events: [String] = []

        private static var clickMonitor: Any?

        /// Notes where each click lands: its window and the view hit-testing returns.
        static func watchClicks() {
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
                MainActor.assumeIsolated {
                    let view = event.window?.contentView.flatMap { content in
                        content.superview?.hitTest(event.locationInWindow) ?? content.hitTest(event.locationInWindow)
                    }
                    note("\(event.type == .leftMouseDown ? "down" : "up") win=\(event.window?.title ?? "nil") key=\(event.window?.isKeyWindow ?? false) hit=\(view.map { String(describing: type(of: $0)) } ?? "nil")")
                }
                return event
            }
        }

        static func note(_ event: String) {
            events.append(event)
            if events.count > 40 { events.removeFirst() }
        }

        static func state() -> [String: Any] {
            let key = NSApp.keyWindow
            return [
                "row": recordingRow ?? NSNull(),
                "sessionActive": ShortcutCaptureSession.shared.isActive,
                "keyWindow": key?.title ?? NSNull(),
                "appActive": NSApp.isActive,
                "firstResponder": key?.firstResponder.map { String(describing: type(of: $0)) } ?? NSNull(),
                "events": events,
            ]
        }
    }

    /// Side effects that `--ui-testing-stub-paste` records instead of posting events.
    enum UITestProbeCounters {
        private static let state = OSAllocatedUnfairLock<(paste: Int, submit: Bool)>(initialState: (0, false))

        static func recordPaste() { state.withLock { $0.paste += 1 } }
        static func recordSubmit() { state.withLock { $0.submit = true } }
        static var pasteCount: Int { state.withLock { $0.paste } }
        static var submitSent: Bool { state.withLock { $0.submit } }
    }

    /// Probe (test-plan 2.7, `--ui-testing-probe`): a 1 x 1 pt non-activating panel at the screen's
    /// bottom-left with one text, `probe.state`, whose value is JSON. Values come from the same
    /// `SettingsStorage` the app reads.
    @MainActor
    final class UITestProbe {
        static let shared = UITestProbe()

        private var panel: NSPanel?
        private let field = NSTextField(labelWithString: "{}")
        private weak var appState: AppState?
        private var timer: Timer?

        func show(appState: AppState) {
            self.appState = appState
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.identifier = NSUserInterfaceItemIdentifier("testProbe")
            panel.setAccessibilityIdentifier("testProbe")
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
            field.setAccessibilityIdentifier("probe.state")
            field.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            panel.contentView?.addSubview(field)
            panel.setFrameOrigin(NSScreen.main?.frame.origin ?? .zero)
            panel.orderFrontRegardless()
            self.panel = panel
            UITestCaptureTrace.watchClicks()
            refresh()
            // App-side polling keeps the probe current; tests wait on its value with a predicate.
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated { UITestProbe.shared.refresh() }
            }
        }

        func refresh() {
            guard panel != nil else { return }
            let json = (try? JSONSerialization.data(withJSONObject: state(), options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            if field.stringValue != json { field.stringValue = json }
        }

        private static func parakeetState(_ state: ModelDownloadState) -> [String: Any] {
            switch state {
            case .notDownloaded: ["state": "notDownloaded"]
            case let .downloading(value): ["state": "downloading", "percent": Int((value * 100).rounded())]
            case .downloaded: ["state": "downloaded"]
            case .failed: ["state": "failed"]
            }
        }

        private func state() -> [String: Any] {
            let store = DictationOverlayController.shared.store
            let settings = SettingsStorage.shared
            var probe: [String: Any] = [
                "seq": UITestBridge.shared.seq,
                "lastAction": UITestBridge.shared.lastAction,
                "surface": settings.recordingFeedbackSurface.rawValue,
                "parakeet": Self.parakeetState(ParakeetModelController.shared.state),
                "pasteCount": UITestProbeCounters.pasteCount,
                "submitSent": UITestProbeCounters.submitSent,
                "registered": KeyboardShortcutsRegistrar.shared.registeredForUITesting(),
                "elevenlabs.hasKey": ProviderKeyStore.shared.hasKey(for: STTProviderID.elevenLabs),
                "session": [
                    "job": "\(store.mode)",
                    "engine": store.sessionEngine?.id.rawValue ?? NSNull(),
                    "segment": store.meetingSegment.rawValue,
                    "pair": "\(store.meetingTranslationPair.languageA)-\(store.meetingTranslationPair.languageB)",
                ] as [String: Any],
            ]
            probe["capture"] = UITestCaptureTrace.state()
            if let appState {
                probe["recording"] = [
                    "voice": appState.recordingState.description,
                    "translation": appState.translationRecordingState.description,
                    "meeting": appState.meetingRecordingState.description,
                    "meetingTranslation": appState.meetingTranslationRecordingState.description,
                ]
            }
            if let bundleID = Bundle.main.bundleIdentifier,
               let domain = settings.defaults.persistentDomain(forName: bundleID)
            {
                probe["store"] = domain.filter { JSONSerialization.isValidJSONObject([$0.value]) }
            }
            return probe
        }
    }
#endif
