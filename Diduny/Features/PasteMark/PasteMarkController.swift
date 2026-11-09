import AppKit
import SwiftUI

@MainActor
final class PasteMarkModel: ObservableObject {
    @Published var phase: LogoBadgePhase = .waiting
    @Published var isVisible = false
    @Published var pulses = 0
}

/// The logo next to the caret after Stop (dictation and its translation). It never delays the paste:
/// it waits at the caret while the text is finalized, then after the paste closes its ring, glides
/// to the end of the new text, pulses once and fades (about 830 ms). Typing or a new recording
/// clears it at once. A non-activating panel that ignores the mouse, so focus stays in the target app.
@MainActor
final class PasteMarkController {
    static let shared = PasteMarkController()

    private final class MarkPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    var geometry: any CaretGeometry = AXCaretGeometry()
    private(set) var phase: PasteMarkPlan.Phase = .idle
    private let model = PasteMarkModel()
    private var panel: NSPanel?
    private var start: CaretPosition?
    private var locateTask: Task<Void, Never>?
    private var landTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var generation = 0

    private init() {}

    /// Stop on a dictation that will paste: find the caret and show the logo with its waiting arc.
    func beginWaiting() {
        clear()
        phase = PasteMarkPlan.next(phase, .finalizing)
        let generation = generation
        let geometry = geometry
        locateTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { geometry.caret() }.value
            guard let self, self.generation == generation else { return }
            self.phase = PasteMarkPlan.next(self.phase, found == nil ? .caretMissing : .caretFound)
            guard let found, self.phase == .waiting else { return }
            self.start = found
            self.show(at: found.rect)
        }
    }

    /// After the paste. `completion(true)` when the logo plays at the caret; false means the
    /// panel header has to carry the signal.
    func land(completion: @escaping @MainActor (Bool) -> Void) {
        let generation = generation
        landTask = Task { [weak self] in
            await self?.locateTask?.value
            guard let self, self.generation == generation, self.phase == .waiting, let start = self.start else {
                self?.clear()
                completion(false)
                return
            }
            self.phase = PasteMarkPlan.next(self.phase, .pasted)
            completion(true)
            await self.playLanding(from: start, generation: generation)
        }
    }

    /// Clears a logo still waiting for its paste (an error, a cancel); a landing finishes on its own.
    func clearIfWaiting() {
        if phase == .locating || phase == .waiting { clear() }
    }

    /// At once, without an exit: a new recording, typing, or nothing pasted.
    func clear() {
        generation += 1
        locateTask?.cancel()
        landTask?.cancel()
        locateTask = nil
        landTask = nil
        start = nil
        phase = .idle
        removeKeyMonitor()
        model.isVisible = false
        panel?.orderOut(nil)
    }

    // MARK: - Landing

    private func playLanding(from start: CaretPosition, generation: Int) async {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let timeline = PasteMarkPlan.timeline(reduceMotion: reduceMotion)
        let began = ContinuousClock.now
        model.phase = .done

        let geometry = geometry
        let end = await Task.detached(priority: .userInitiated) {
            await PasteMarkPlan.pollPastedEnd(geometry: geometry, before: start.location)
        }.value
        guard !Task.isCancelled, self.generation == generation else { return }
        let found = end.map { _ in (ContinuousClock.now - began).seconds }
        let landing = PasteMarkPlan.landing(endFoundAfter: found, reduceMotion: reduceMotion)
        if landing.glides, let end { glide(to: end.rect, duration: timeline.glide) }
        if let pulseAt = landing.pulseAt {
            guard await sleep(until: began + .seconds(pulseAt), generation: generation) else { return }
            model.pulses += 1
        }
        guard await sleep(until: began + .seconds(landing.fadeAt), generation: generation) else { return }
        model.isVisible = false
        guard await sleep(until: began + .seconds(landing.fadeAt + timeline.fade), generation: generation) else { return }
        clear()
    }

    private func sleep(until deadline: ContinuousClock.Instant, generation: Int) async -> Bool {
        try? await Task.sleep(until: deadline, clock: .continuous)
        return !Task.isCancelled && self.generation == generation
    }

    // MARK: - Panel

    private func show(at caret: CGRect) {
        if panel == nil { panel = makePanel() }
        model.phase = .waiting
        model.isVisible = false
        panel?.setFrame(frame(caret: caret), display: false)
        panel?.orderFrontRegardless()
        model.isVisible = true
        installKeyMonitor()
    }

    private func glide(to caret: CGRect, duration: TimeInterval) {
        guard let panel else { return }
        let target = frame(caret: caret)
        guard target != panel.frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func frame(caret: CGRect) -> CGRect {
        let screens = NSScreen.screens.map {
            InplaceTranslationAnchor.ScreenInfo(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let disc = InplaceTranslationAnchor.panelFrame(
            size: CGSize(width: PasteMarkPlan.disc, height: PasteMarkPlan.disc),
            selectionEnd: caret, mouse: NSEvent.mouseLocation, screens: screens
        )
        return disc.insetBy(dx: -PasteMarkPlan.panelMargin, dy: -PasteMarkPlan.panelMargin)
    }

    private func makePanel() -> NSPanel {
        let side = PasteMarkPlan.disc + 2 * PasteMarkPlan.panelMargin
        let panel = MarkPanel(
            contentRect: CGRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: PasteMarkView(model: model))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    // MARK: - Typing

    /// Listen-only global monitor, live only while the logo is on screen. It needs the
    /// Accessibility permission auto-paste already uses; without it, it never fires and the logo
    /// still ends on its own in 830 ms.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags
            Task { @MainActor in
                guard PasteMarkPlan.keyDownClears(modifiers: modifiers) else { return }
                PasteMarkController.shared.clear()
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

private struct PasteMarkView: View {
    @ObservedObject var model: PasteMarkModel

    var body: some View {
        LogoBadge(phase: model.phase, isVisible: model.isVisible, pulseTrigger: model.pulses)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
