import AppKit
import SwiftUI

@MainActor
final class EdgeCommandPanelController: NSObject {
    static let shared = EdgeCommandPanelController()
    static let panelIdentifier = NSUserInterfaceItemIdentifier(
        "commandPanel"
    )

    weak var appDelegate: AppDelegate?
    private var panel: EdgeCommandPanel?
    var panelContentView: EdgeCommandPanelContentView?
    var model: EdgeCommandPanelModel?
    private let meetingRecordingStarter: ((TranscriptionProvider) -> Void)?
    private var collapseTask: Task<Void, Never>?
    var dock: EdgeCommandPanelDock?
    var dragCursorOffset: NSPoint?

    // Collapsed-tab auto-hide state (the tab annoys people when it sits on
    // the screen edge permanently).
    private var tabAutoHideTask: Task<Void, Never>?
    private var edgeRevealGlobalMonitor: Any?
    private var edgeRevealLocalMonitor: Any?
    private var isTabHidden = false
    private var hiddenTabScreenFrame: NSRect?
    /// After the user click-restores a minimized live panel, keep it open for
    /// the rest of the session even if "show modal on start" is off.
    private var liveFeedbackRestoredByUser = false

    init(meetingRecordingStarter: ((TranscriptionProvider) -> Void)? = nil) {
        self.meetingRecordingStarter = meetingRecordingStarter
        super.init()
    }

    func configure(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        refreshModel()
        applySurfacePreference()
    }

    /// The edge panel exists only for the Floating modal surface. In Dynamic
    /// Notch mode nothing of it may be on screen — feedback lives in the
    /// notch. Called at launch and whenever the Settings picker changes.
    func applySurfacePreference() {
        // Never clobber an active live session (expanded or minimized to the
        // red-dot tab) or a meeting suggestion — those own the panel until
        // they dismiss themselves.
        let isBusy = model?.isShowingLiveFeedback == true
            || model?.isLiveFeedbackMinimized == true
            || model?.meetingSuggestion != nil
        if SettingsStorage.shared.recordingFeedbackSurface == .notch {
            // An active live-feedback session finishes on the panel (the
            // router snapshots the surface per session) — hide right after,
            // via dismissLiveFeedback → showCollapsed's notch guard.
            guard !isBusy else { return }
            hidePanelForNotchMode()
        } else {
            guard !isBusy else { return }
            showCollapsed()
        }
    }

    private func hidePanelForNotchMode() {
        collapseTask?.cancel()
        tabAutoHideTask?.cancel()
        removeEdgeRevealMonitors()
        isTabHidden = false
        model?.isShowingLiveFeedback = false
        model?.isLiveFeedbackMinimized = false
        model?.isExpanded = false
        concealPanel()
    }

    /// Hides the panel by fading it out instead of ordering it out of the
    /// window list — orderOut drops the visual-effect view's shape mask, and
    /// the material comes back with square corners on the next show.
    private func concealPanel() {
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }
    }

    private func revealPanelIfConcealed() {
        guard let panel else { return }
        panel.ignoresMouseEvents = false
        guard panel.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func refreshModel() {
        let pairs = SettingsStorage.shared.translationLanguagePairs
        let selected = SettingsStorage.shared.resolveTranslationLanguagePair()
        let isSignedIn = AuthService.hasStoredSession
        let provider: TranscriptionProvider = isSignedIn
            && SettingsStorage.shared.effectiveTranscriptionProvider == .cloud
            && SettingsStorage.shared.effectiveTranslationProvider == .cloud ? .cloud : .local
        if let model {
            model.refresh(
                pairs: pairs,
                selectedPair: selected,
                provider: provider,
                isSignedIn: isSignedIn
            )
        } else {
            model = EdgeCommandPanelModel(
                pairs: pairs,
                selectedPair: selected,
                provider: provider,
                isSignedIn: isSignedIn
            )
        }
    }

    func showCollapsed() {
        // Minimized live owns the edge tab until click-restore or recording end.
        // Idle collapse must not wipe it into the ribbon command tab.
        if model?.isLiveFeedbackMinimized == true {
            presentMinimizedLiveTab()
            return
        }
        // In notch mode the panel must never surface, whatever path led here.
        guard SettingsStorage.shared.recordingFeedbackSurface != .notch else {
            hidePanelForNotchMode()
            return
        }
        collapseTask?.cancel()
        cancelTabAutoHide()
        let panel = panel ?? makePanel()
        self.panel = panel
        model?.isShowingLiveFeedback = false
        model?.isLiveFeedbackMinimized = false
        position(panel, presentation: .collapsed)
        refreshTabRootView()
        revealPanelIfConcealed()
        panel.orderFrontRegardless()
        scheduleTabAutoHide()
    }

    private func showExpanded() {
        guard EdgeCommandPanelMinimizedLivePolicy.shouldAllowHoverExpand(
            isLiveFeedbackMinimized: model?.isLiveFeedbackMinimized == true
        ) else { return }
        collapseTask?.cancel()
        cancelTabAutoHide()
        refreshModel()
        let panel = panel ?? makePanel()
        self.panel = panel
        model?.isShowingLiveFeedback = false
        model?.isLiveFeedbackMinimized = false
        position(panel, presentation: commandPresentation)
        revealPanelIfConcealed()
        panel.orderFrontRegardless()
    }

    func showLiveFeedback(mode: RecordingMode) {
        // Phase updates keep calling this while recording. If the user hid the
        // live panel, leave it collapsed until they restore it intentionally.
        if model?.isLiveFeedbackMinimized == true {
            model?.meetingSuggestion = nil
            return
        }
        if shouldStartLiveFeedbackMinimized {
            model?.meetingSuggestion = nil
            model?.isShowingLiveFeedback = true
            model?.isLiveFeedbackMinimized = true
            presentMinimizedLiveTab()
            return
        }
        collapseTask?.cancel()
        cancelTabAutoHide()
        let panel = panel ?? makePanel()
        self.panel = panel
        model?.meetingSuggestion = nil
        // A fresh appearance morphs the edge tab into the panel. Phase updates
        // re-enter here while live, so only the first call animates.
        dismissTask?.cancel()
        let alreadyLive = model?.isShowingLiveFeedback == true && model?.isLiveFeedbackMinimized != true
        let shouldMorph = !alreadyLive
        model?.isLiveFeedbackMinimized = false
        model?.isShowingLiveFeedback = true
        position(panel, presentation: .live(mode), morphFromTab: shouldMorph)
        if !shouldMorph { revealPanelIfConcealed() }
        panel.orderFrontRegardless()
    }

    /// Collapse the live recording panel to the edge tab without stopping capture.
    /// The red-dot tab auto-hides like the idle tab; edge hover brings it back,
    /// and only a click restores the transcript modal.
    func minimizeLiveFeedback() {
        guard model?.isShowingLiveFeedback == true || model?.isLiveFeedbackMinimized == true else { return }
        guard SettingsStorage.shared.recordingFeedbackSurface != .notch else { return }
        model?.isLiveFeedbackMinimized = true
        presentMinimizedLiveTab()
    }

    /// Re-assert the red-dot tab without clearing live/minimized flags, then
    /// schedule the usual edge-tab auto-hide.
    private func presentMinimizedLiveTab() {
        collapseTask?.cancel()
        cancelTabAutoHide()
        let panel = panel ?? makePanel()
        self.panel = panel
        model?.isShowingLiveFeedback = true
        model?.isLiveFeedbackMinimized = true
        position(panel, presentation: .collapsed)
        refreshTabRootView()
        revealPanelIfConcealed()
        panel.orderFrontRegardless()
        scheduleTabAutoHide()
    }

    private func restoreMinimizedLiveFeedback() {
        guard model?.isLiveFeedbackMinimized == true else { return }
        liveFeedbackRestoredByUser = true
        model?.isLiveFeedbackMinimized = false
        refreshTabRootView()
        showLiveFeedback(mode: DictationOverlayController.shared.store.mode)
    }

    private var shouldStartLiveFeedbackMinimized: Bool {
        SettingsStorage.shared.recordingFeedbackSurface == .compactPanel
            && !SettingsStorage.shared.showLiveTranscriptModal
            && !liveFeedbackRestoredByUser
    }

    func showMeetingSuggestion(_ meeting: DetectedMeeting) {
        collapseTask?.cancel()
        cancelTabAutoHide()
        refreshModel()
        let cloudAvailable = UsageService.canOfferCloudTranscription(
            hasStoredSession: AuthService.hasStoredSession,
            usage: UsageService.shared.cachedUsage
        )
        let suggestion = MeetingSuggestion.resolve(
            meeting: meeting,
            preferredProvider: SettingsStorage.shared.meetingRealtimeTranscriptionEnabled ? .cloud : .local,
            cloudAvailable: cloudAvailable,
            hasLocalModel: WhisperModelManager.shared.selectedModel() != nil
        )
        model?.presentMeetingSuggestion(suggestion)
        model?.isShowingLiveFeedback = false
        let panel = panel ?? makePanel()
        self.panel = panel
        position(
            panel,
            presentation: .meetingSuggestion
        )
        revealPanelIfConcealed()
        panel.orderFrontRegardless()
    }

    @discardableResult
    func selectMeetingSuggestionProvider(_ provider: TranscriptionProvider) -> Bool {
        model?.selectMeetingSuggestionProvider(provider) ?? false
    }

    func dismissMeetingSuggestion(id: UUID) {
        guard model?.meetingSuggestion?.meeting.id == id else { return }
        model?.dismissMeetingSuggestion(id: id)
        restoreConfiguredSurface()
    }

    func startMeetingRecording(fromSuggestionID id: UUID) {
        guard let suggestion = model?.consumeMeetingSuggestionStart(id: id) else { return }
        restoreConfiguredSurface()
        if let meetingRecordingStarter {
            meetingRecordingStarter(suggestion.selectedProvider)
            return
        }
        guard let appDelegate,
              !appDelegate.hasAnyRecordingInProgress,
              appDelegate.canStartRecording(kind: .meeting)
        else { return }
        appDelegate.toggleMeetingRecording(provider: suggestion.selectedProvider)
    }

    private func setMeetingSuggestionsEnabled(_ enabled: Bool) {
        model?.meetingSuggestionsEnabled = enabled
        SettingsStorage.shared.meetingSuggestionsEnabled = enabled
    }

    private func restoreConfiguredSurface() {
        if SettingsStorage.shared.recordingFeedbackSurface == .notch {
            hidePanelForNotchMode()
        } else {
            showCollapsed()
        }
    }

    // MARK: - Collapsed-tab auto-hide

    private func cancelTabAutoHide() {
        tabAutoHideTask?.cancel()
        removeEdgeRevealMonitors()
        isTabHidden = false
    }

    private func scheduleTabAutoHide() {
        guard EdgeCommandPanelAutoHidePolicy.shouldSchedule(
            isLiveFeedbackMinimized: model?.isLiveFeedbackMinimized == true
        ) else { return }
        tabAutoHideTask?.cancel()
        tabAutoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(EdgeCommandPanelAutoHidePolicy.delay))
            guard !Task.isCancelled, let self, let panel else { return }
            // Re-check after sleep — minimize may have started while we waited.
            guard EdgeCommandPanelAutoHidePolicy.shouldSchedule(
                isLiveFeedbackMinimized: model?.isLiveFeedbackMinimized == true
            ) else { return }
            guard EdgeCommandPanelAutoHidePolicy.shouldHide(
                pointer: NSEvent.mouseLocation,
                panelFrame: panel.frame,
                isDragging: dragCursorOffset != nil,
                isExpanded: model?.isExpanded == true,
                isShowingLiveFeedback: model?.isShowingLiveFeedback == true,
                isLiveFeedbackMinimized: model?.isLiveFeedbackMinimized == true
            ) else {
                // Busy or hovered — try again after another idle interval.
                scheduleTabAutoHide()
                return
            }
            hideTab()
        }
    }

    private func hideTab() {
        guard let panel else { return }
        isTabHidden = true
        hiddenTabScreenFrame = panel.screen?.frame
        concealPanel()
        installEdgeRevealMonitors()
    }

    private func revealTabIfPointerAtEdge(_ location: NSPoint) {
        guard isTabHidden else { return }
        let screenFrame = hiddenTabScreenFrame
            ?? NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) })?.frame
        guard let screenFrame else { return }
        guard EdgeCommandPanelPlacement.edgeHotZoneContains(
            location,
            screenFrame: screenFrame,
            edge: dock?.edge ?? .right
        ) else { return }
        // A minimized live tab must come back as the red-dot tab — never via
        // showCollapsed(), which would reset it to the idle command tab.
        if model?.isLiveFeedbackMinimized == true {
            isTabHidden = false
            removeEdgeRevealMonitors()
            refreshTabRootView()
            revealPanelIfConcealed()
            panel?.orderFrontRegardless()
            scheduleTabAutoHide()
            return
        }
        showCollapsed()
    }

    private func installEdgeRevealMonitors() {
        guard edgeRevealGlobalMonitor == nil else { return }
        edgeRevealGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.revealTabIfPointerAtEdge(NSEvent.mouseLocation)
            }
        }
        edgeRevealLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.revealTabIfPointerAtEdge(NSEvent.mouseLocation)
            }
            return event
        }
    }

    private func removeEdgeRevealMonitors() {
        if let edgeRevealGlobalMonitor {
            NSEvent.removeMonitor(edgeRevealGlobalMonitor)
            self.edgeRevealGlobalMonitor = nil
        }
        if let edgeRevealLocalMonitor {
            NSEvent.removeMonitor(edgeRevealLocalMonitor)
            self.edgeRevealLocalMonitor = nil
        }
    }

    func dismissLiveFeedback() {
        guard model?.isShowingLiveFeedback == true || model?.isLiveFeedbackMinimized == true else { return }
        // Clear minimized first so showCollapsed proceeds to the idle ribbon tab.
        liveFeedbackRestoredByUser = false
        let store = DictationOverlayController.shared.store
        let wasExpanded = model?.isShowingLiveFeedback == true && model?.isLiveFeedbackMinimized != true
        model?.isLiveFeedbackMinimized = false
        model?.isShowingLiveFeedback = false
        // Stop: content fades first, then the panel folds back into its tab.
        guard wasExpanded, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            store.contentRevealed = true
            showCollapsed()
            return
        }
        store.contentRevealed = false
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            showCollapsed()
            store.contentRevealed = true
        }
    }

    private var dismissTask: Task<Void, Never>?

    /// True while a live recording is hidden to the red-dot edge tab.
    var isLiveFeedbackMinimized: Bool {
        model?.isLiveFeedbackMinimized == true
    }

    private func setHovering(_ hovering: Bool) {
        // Minimized live recording restores only via click — hover must never expand.
        guard EdgeCommandPanelMinimizedLivePolicy.shouldAllowHoverExpand(
            isLiveFeedbackMinimized: model?.isLiveFeedbackMinimized == true
        ) else { return }
        guard model?.isShowingLiveFeedback != true, model?.meetingSuggestion == nil else { return }
        if hovering {
            collapseTask?.cancel()
            tabAutoHideTask?.cancel()
            guard model?.isExpanded != true else { return }
            showExpanded()
        } else {
            guard model?.isExpanded == true else { return }
            collapseTask?.cancel()
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self, let panel else { return }
                guard EdgeCommandPanelHoverPolicy.shouldCollapse(
                    pointer: NSEvent.mouseLocation,
                    panelFrame: panel.frame,
                    isDragging: dragCursorOffset != nil
                ) else { return }
                showCollapsed()
            }
        }
    }

    private func dragPanel() {
        guard let panel else { return }
        collapseTask?.cancel()
        let cursor = NSEvent.mouseLocation
        if dragCursorOffset == nil {
            dragCursorOffset = NSPoint(x: cursor.x - panel.frame.minX, y: cursor.y - panel.frame.minY)
        }
        guard let dragCursorOffset else { return }
        panel.setFrameOrigin(NSPoint(x: cursor.x - dragCursorOffset.x, y: cursor.y - dragCursorOffset.y))
    }

    private func finishDraggingPanel() {
        guard let panel, dragCursorOffset != nil else { return }
        dragCursorOffset = nil
        let screen = activeScreen() ?? panel.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let newDock = EdgeCommandPanelPlacement.nearestDock(to: panel.frame, in: visibleFrame)
        dock = newDock
        model?.dockEdge = newDock.edge
        SettingsStorage.shared.edgePanelDockEdge = newDock.edge.rawValue
        SettingsStorage.shared.edgePanelDockOffset = Double(newDock.offset)
        position(panel, presentation: currentPresentation, on: visibleFrame)
        if currentPresentation == .collapsed {
            scheduleTabAutoHide()
        }
    }

    private func selectProvider(_ provider: TranscriptionProvider) {
        guard let model, model.selectProvider(provider) else {
            openAccount()
            return
        }
        SettingsStorage.shared.selectProcessingProvider(provider)
        if let panel {
            position(panel, presentation: commandPresentation)
        }
    }

    private func openAccount() {
        appDelegate?.openMainWindow(section: .account)
    }

    private func makePanel() -> EdgeCommandPanel {
        let panel = EdgeCommandPanel(
            contentRect: NSRect(origin: .zero, size: EdgeCommandPanelPlacement.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = Self.panelIdentifier
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true

        let contentView = EdgeCommandPanelContentView(
            tabView: makeTabView(),
            expandedView: makeExpandedView(),
            onHoverChange: { [weak self] hovering in self?.setHovering(hovering) }
        )
        panelContentView = contentView
        panel.contentView = contentView
        return panel
    }

    private func makeTabView() -> EdgeCommandTabView {
        EdgeCommandTabView(
            model: model!,
            onExpand: { [weak self] in
                guard let self else { return }
                if model?.isLiveFeedbackMinimized == true {
                    restoreMinimizedLiveFeedback()
                } else {
                    showExpanded()
                }
            },
            onDrag: { [weak self] in self?.dragPanel() },
            onDragEnd: { [weak self] in self?.finishDraggingPanel() }
        )
    }

    private func makeExpandedView() -> EdgeCommandExpandedView {
        EdgeCommandExpandedView(
            model: model!,
            liveStore: DictationOverlayController.shared.store,
            onAction: { [weak self] action in self?.perform(action) },
            onProvider: { [weak self] provider in self?.selectProvider(provider) },
            onSignIn: { [weak self] in self?.openAccount() },
            onCopy: { DictationOverlayController.shared.copyCurrentTranscript() },
            onStop: { DictationOverlayController.shared.requestStop() },
            onDismissLive: { DictationOverlayController.shared.dismiss() },
            onMinimizeLive: { [weak self] in self?.minimizeLiveFeedback() },
            onSelectOutput: { DictationOverlayController.shared.selectOutput($0) },
            onStartMeetingSuggestion: { [weak self] id in
                self?.startMeetingRecording(fromSuggestionID: id)
            },
            onDismissMeetingSuggestion: { [weak self] id in
                self?.dismissMeetingSuggestion(id: id)
            },
            onMeetingSuggestionsEnabled: { [weak self] enabled in
                self?.setMeetingSuggestionsEnabled(enabled)
            },
            onCollapse: { [weak self] in self?.showCollapsed() },
            onDrag: { [weak self] in self?.dragPanel() },
            onDragEnd: { [weak self] in self?.finishDraggingPanel() }
        )
    }

    /// Force the tab hosting view to rebuild so red-dot vs ribbon updates immediately.
    private func refreshTabRootView() {
        guard model != nil else { return }
        panelContentView?.updateTabView(makeTabView())
    }

    private var commandPresentation: EdgeCommandPanelPresentation {
        .commands(isCloud: model?.provider == .cloud)
    }

    var currentPresentation: EdgeCommandPanelPresentation {
        guard let model else { return .collapsed }
        if model.meetingSuggestion != nil {
            return .meetingSuggestion
        }
        // Minimized live recording keeps the edge tab until click-restore.
        if model.isLiveFeedbackMinimized {
            return .collapsed
        }
        if model.isShowingLiveFeedback {
            return .live(DictationOverlayController.shared.store.mode)
        }
        return model.isExpanded ? commandPresentation : .collapsed
    }
}
