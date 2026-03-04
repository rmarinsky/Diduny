import AppKit
import Foundation

@MainActor
final class DoubleCopyDetector {
    static let shared = DoubleCopyDetector()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastCmdCTime: TimeInterval = 0
    private var handler: ((String) -> Void)?

    private let threshold: TimeInterval = 0.35

    private init() {}

    func start(handler: @escaping (String) -> Void) {
        self.handler = handler

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyEvent(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyEvent(event)
            }
            return event
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        handler = nil
        lastCmdCTime = 0
    }

    private func handleKeyEvent(_ event: NSEvent) {
        // keyCode 8 = C key, check for Cmd modifier only (no Shift/Option/Ctrl)
        guard event.keyCode == 8,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastCmdCTime
        lastCmdCTime = now

        if elapsed < threshold {
            // Reset to prevent triple-C triggering twice
            lastCmdCTime = 0

            // Small delay to let the second Cmd+C copy finish
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, let handler = self.handler else { return }

                if let text = NSPasteboard.general.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                {
                    handler(text)
                }
            }
        }
    }
}
