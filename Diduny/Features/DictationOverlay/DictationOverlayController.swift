import AppKit
import SwiftUI

@MainActor
final class DictationOverlayController {
    static let shared = DictationOverlayController()

    private let store = LiveDictationOverlayStore()
    private var panel: NSPanel?
    private var autoHideTask: Task<Void, Never>?
    private var onStopRequested: (@MainActor () async -> Void)?

    private init() {}

    func setStopHandler(_ handler: (@MainActor () async -> Void)?) {
        onStopRequested = handler
    }

    func begin(mode: RecordingMode) {
        autoHideTask?.cancel()
        store.reset(mode: mode)
        store.phase = .starting
        showPanel()
    }

    func startRecording(mode: RecordingMode) {
        autoHideTask?.cancel()
        if store.mode != mode {
            store.reset(mode: mode)
        }
        store.phase = .recording
        showPanel()
    }

    func startFinalizing(mode: RecordingMode) {
        autoHideTask?.cancel()
        if store.mode != mode {
            store.mode = mode
        }
        store.phase = .finalizing
        store.audioLevel = 0
        showPanel()
    }

    func startProcessing(mode: RecordingMode) {
        autoHideTask?.cancel()
        if store.mode != mode {
            store.mode = mode
        }
        store.phase = .processing
        store.audioLevel = 0
        showPanel()
    }

    func showSuccess(text: String) {
        autoHideTask?.cancel()
        if !text.isEmpty {
            store.finalText = text
            store.provisionalText = ""
        }
        store.phase = .pasted
        store.audioLevel = 0
        showPanel()
        scheduleAutoHide(delay: 2.0)
    }

    func showError(message: String) {
        autoHideTask?.cancel()
        store.phase = .error(message)
        store.audioLevel = 0
        showPanel()
        scheduleAutoHide(delay: 3.0)
    }

    func showInfo(message: String, duration: TimeInterval = 1.5) {
        autoHideTask?.cancel()
        store.phase = .info(message)
        store.audioLevel = 0
        showPanel()
        scheduleAutoHide(delay: duration)
    }

    func showInfoDuringRecording(message: String, mode: RecordingMode, duration: TimeInterval = 1.5) {
        autoHideTask?.cancel()
        let savedPhase = store.phase
        let savedStart = store.startedAt
        store.mode = mode
        store.phase = .info(message)
        showPanel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.store.startedAt = savedStart
                self.store.phase = savedPhase
                self.showPanel()
            }
        }
    }

    func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        store.audioLevel = 0
        panel?.orderOut(nil)
        panel = nil
    }

    func updateAudioLevel(_ level: Float) {
        store.audioLevel = max(0, min(level, 1))
    }

    func processTokens(_ tokens: [RealtimeToken]) {
        guard !tokens.isEmpty else { return }
        store.processTokens(tokens)
    }

    func updateConnectionStatus(_ status: RealtimeConnectionStatus) {
        store.connectionStatus = status
    }

    func copyCurrentTranscript() {
        let text = store.bestText(includeProvisional: true)
        guard !text.isEmpty else { return }
        ClipboardService.shared.copy(text: text, behavior: .raw)
        store.markCopied()
    }

    func requestStop() {
        guard let onStopRequested else { return }
        Task { @MainActor in
            await onStopRequested()
        }
    }

    private func showPanel() {
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = DictationOverlayPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 560, height: 96)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        let view = LiveDictationOverlayView(
            store: store,
            onCopy: { [weak self] in self?.copyCurrentTranscript() },
            onStop: { [weak self] in self?.requestStop() }
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: 560, height: 96))
        panel.contentView = hostingView
        return panel
    }

    private func position(_ panel: NSPanel) {
        let size = NSSize(width: 560, height: 96)
        let screen = activeScreen() ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 18
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }

    private func scheduleAutoHide(delay: TimeInterval) {
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.hide()
            }
        }
    }
}

private final class DictationOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
