import AppKit
import Observation
import QuartzCore
import SwiftUI

enum EdgeCommandAction: CaseIterable, Identifiable {
    case transcribe
    case translate
    case meeting
    case translateMeeting
    case batch

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .transcribe: String(localized: "Transcribe")
        case .translate: String(localized: "Translate")
        case .meeting: String(localized: "Record meeting")
        case .translateMeeting: String(localized: "Translate meeting")
        case .batch: String(localized: "Batch files")
        }
    }

    var icon: String {
        switch self {
        case .transcribe: "waveform"
        case .translate: "character.bubble"
        case .meeting: "record.circle"
        case .translateMeeting: "captions.bubble"
        case .batch: "tray.full"
        }
    }

    var usesLanguagePair: Bool {
        self == .translate || self == .translateMeeting
    }
}

enum EdgeCommandPanelDockEdge: String, Equatable {
    case left
    case right
    case top
    case bottom
}

struct EdgeCommandPanelDock: Equatable {
    let edge: EdgeCommandPanelDockEdge
    let offset: CGFloat

    init(edge: EdgeCommandPanelDockEdge, offset: CGFloat) {
        self.edge = edge
        self.offset = offset
    }

    /// Restores a dock persisted as raw values; nil when either value is
    /// missing or the edge name is unknown. A stale offset from a
    /// disconnected screen is safe — placement clamps it to the visible frame.
    init?(rawEdge: String?, offset: Double?) {
        guard let rawEdge, let edge = EdgeCommandPanelDockEdge(rawValue: rawEdge), let offset else {
            return nil
        }
        self.init(edge: edge, offset: CGFloat(offset))
    }
}

enum EdgeCommandPanelPresentation: Equatable {
    case collapsed
    case commands(isCloud: Bool)
    case live(RecordingMode)
    case meetingSuggestion
}

enum MeetingSuggestionProcessingMode: Equatable {
    case cloud
    case local
    case recordingOnly

    static func resolve(cloudEnabled: Bool, hasLocalModel: Bool) -> Self {
        if cloudEnabled { return .cloud }
        return hasLocalModel ? .local : .recordingOnly
    }

    var label: String {
        switch self {
        case .cloud: String(localized: "Cloud - live transcription")
        case .local: String(localized: "Local - transcription on this Mac")
        case .recordingOnly:
            String(localized: "Recording only - download a local model for transcription")
        }
    }

    var icon: String {
        switch self {
        case .cloud: "cloud"
        case .local: "desktopcomputer"
        case .recordingOnly: "exclamationmark.triangle"
        }
    }
}

struct MeetingSuggestion: Equatable {
    let meeting: DetectedMeeting
    var selectedProvider: TranscriptionProvider
    var isCloudAvailable: Bool
    let hasLocalModel: Bool

    var processingMode: MeetingSuggestionProcessingMode {
        .resolve(cloudEnabled: selectedProvider == .cloud, hasLocalModel: hasLocalModel)
    }

    static func resolve(
        meeting: DetectedMeeting,
        preferredProvider: TranscriptionProvider,
        cloudAvailable: Bool,
        hasLocalModel: Bool
    ) -> Self {
        Self(
            meeting: meeting,
            selectedProvider: preferredProvider == .cloud && cloudAvailable ? .cloud : .local,
            isCloudAvailable: cloudAvailable,
            hasLocalModel: hasLocalModel
        )
    }
}

enum EdgeCommandPanelPlacement {
    static let expandedCornerRadius: CGFloat = 15
    static let liveControlHitTargetHeight: CGFloat = 44
    static let meetingSuggestionControlHitTargetHeight: CGFloat = 44

    static func nearestDock(to proposedFrame: NSRect, in visibleFrame: NSRect) -> EdgeCommandPanelDock {
        let distances: [(EdgeCommandPanelDockEdge, CGFloat)] = [
            (.left, abs(proposedFrame.minX - visibleFrame.minX)),
            (.right, abs(visibleFrame.maxX - proposedFrame.maxX)),
            (.bottom, abs(proposedFrame.minY - visibleFrame.minY)),
            (.top, abs(visibleFrame.maxY - proposedFrame.maxY))
        ]
        let edge = distances.min(by: { $0.1 < $1.1 })?.0 ?? .right
        let offset = edge == .left || edge == .right ? proposedFrame.midY : proposedFrame.midX
        return EdgeCommandPanelDock(edge: edge, offset: offset)
    }

    static func frame(
        in visibleFrame: NSRect,
        dock: EdgeCommandPanelDock,
        presentation: EdgeCommandPanelPresentation
    ) -> NSRect {
        let size = size(for: presentation, edge: dock.edge)
        let origin = switch dock.edge {
        case .left:
            NSPoint(
                x: visibleFrame.minX,
                y: clampedOrigin(
                    dock.offset,
                    length: size.height,
                    minimum: visibleFrame.minY,
                    maximum: visibleFrame.maxY
                )
            )
        case .right:
            NSPoint(
                x: visibleFrame.maxX - size.width,
                y: clampedOrigin(
                    dock.offset,
                    length: size.height,
                    minimum: visibleFrame.minY,
                    maximum: visibleFrame.maxY
                )
            )
        case .top:
            NSPoint(
                x: clampedOrigin(
                    dock.offset,
                    length: size.width,
                    minimum: visibleFrame.minX,
                    maximum: visibleFrame.maxX
                ),
                y: visibleFrame.maxY - size.height
            )
        case .bottom:
            NSPoint(
                x: clampedOrigin(
                    dock.offset,
                    length: size.width,
                    minimum: visibleFrame.minX,
                    maximum: visibleFrame.maxX
                ),
                y: visibleFrame.minY
            )
        }

        return NSRect(origin: origin, size: size)
    }

    static func frame(in visibleFrame: NSRect, dock: EdgeCommandPanelDock, expanded: Bool) -> NSRect {
        frame(
            in: visibleFrame,
            dock: dock,
            presentation: expanded ? .commands(isCloud: true) : .collapsed
        )
    }

    static func size(
        for presentation: EdgeCommandPanelPresentation,
        edge: EdgeCommandPanelDockEdge
    ) -> NSSize {
        switch presentation {
        case .collapsed:
            collapsedSize(for: edge)
        case let .commands(isCloud):
            NSSize(width: 286, height: isCloud ? 326 : 250)
        case let .live(mode):
            mode.isMeeting ? NSSize(width: 360, height: 420) : NSSize(width: 310, height: 310)
        case .meetingSuggestion:
            NSSize(width: 390, height: 350)
        }
    }

    static let expandedSize = NSSize(width: 286, height: 326)

    private static func collapsedSize(for edge: EdgeCommandPanelDockEdge) -> NSSize {
        switch edge {
        case .left, .right: NSSize(width: 14, height: 64)
        case .top, .bottom: NSSize(width: 64, height: 14)
        }
    }

    private static func clampedOrigin(_ offset: CGFloat, length: CGFloat, minimum: CGFloat,
                                      maximum: CGFloat) -> CGFloat
    {
        min(max(offset - length / 2, minimum), maximum - length)
    }

    /// Whether a pointer location counts as touching the given screen edge —
    /// the reveal gesture for an auto-hidden tab (same idea as the Dock).
    static func edgeHotZoneContains(
        _ location: NSPoint,
        screenFrame: NSRect,
        edge: EdgeCommandPanelDockEdge,
        threshold: CGFloat = 2
    ) -> Bool {
        guard NSMouseInRect(location, screenFrame, false) else { return false }
        return switch edge {
        case .left: location.x <= screenFrame.minX + threshold
        case .right: location.x >= screenFrame.maxX - threshold
        case .top: location.y >= screenFrame.maxY - threshold
        case .bottom: location.y <= screenFrame.minY + threshold
        }
    }
}

enum EdgeCommandPanelHoverPolicy {
    static func shouldCollapse(pointer: NSPoint, panelFrame: NSRect, isDragging: Bool) -> Bool {
        !isDragging && !panelFrame.contains(pointer)
    }
}

/// The collapsed edge tab auto-hides after a few idle seconds (it annoys
/// people when it sits on the screen edge permanently). It must never hide
/// under the pointer, mid-drag, or while the expanded live modal is open.
/// A minimized live-recording tab (red dot) does auto-hide, then reappears
/// on edge hover until the user clicks to restore the modal.
enum EdgeCommandPanelAutoHidePolicy {
    static let delay: TimeInterval = 3

    static func shouldHide(
        pointer: NSPoint,
        panelFrame: NSRect,
        isDragging: Bool,
        isExpanded: Bool,
        isShowingLiveFeedback: Bool,
        isLiveFeedbackMinimized: Bool = false
    ) -> Bool {
        let liveModalExpanded = isShowingLiveFeedback && !isLiveFeedbackMinimized
        return !isDragging
            && !isExpanded
            && !liveModalExpanded
            && !panelFrame.contains(pointer)
    }

    /// Auto-hide may run for idle tabs and for minimized live tabs.
    static func shouldSchedule(isLiveFeedbackMinimized _: Bool) -> Bool {
        true
    }
}

enum EdgeCommandPanelMinimizedLivePolicy {
    /// Hover may open the command menu only when live recording is not minimized.
    static func shouldAllowHoverExpand(isLiveFeedbackMinimized: Bool) -> Bool {
        !isLiveFeedbackMinimized
    }
}

@Observable
@MainActor
final class EdgeCommandPanelModel {
    var pairs: [TranslationLanguagePair]
    var selectedPairID: String
    var provider: TranscriptionProvider
    var isSignedIn: Bool
    var isExpanded = false
    var isShowingLiveFeedback = false
    /// Live recording is active but the user collapsed the panel to the edge tab.
    var isLiveFeedbackMinimized = false
    var meetingSuggestion: MeetingSuggestion?
    var meetingSuggestionsEnabled = SettingsStorage.shared.meetingSuggestionsEnabled
    var dockEdge: EdgeCommandPanelDockEdge = .right

    init(
        pairs: [TranslationLanguagePair],
        selectedPair: TranslationLanguagePair,
        provider: TranscriptionProvider = .local,
        isSignedIn: Bool = true
    ) {
        let normalizedPairs = pairs.isEmpty ? [.defaultPair] : pairs
        self.pairs = normalizedPairs
        self.provider = provider
        self.isSignedIn = isSignedIn
        selectedPairID = normalizedPairs.contains(selectedPair) ? selectedPair.id : normalizedPairs[0].id
    }

    var availableActions: [EdgeCommandAction] {
        if provider == .cloud {
            return [.transcribe, .translate, .meeting, .translateMeeting]
        }
        return [.transcribe, .meeting]
    }

    var showsTranslationControls: Bool {
        provider == .cloud
    }

    var selectedPair: TranslationLanguagePair? {
        pairs.first(where: { $0.id == selectedPairID }) ?? pairs.first
    }

    func select(_ pair: TranslationLanguagePair) {
        guard pairs.contains(pair) else { return }
        selectedPairID = pair.id
    }

    @discardableResult
    func selectProvider(_ provider: TranscriptionProvider) -> Bool {
        guard provider != .cloud || isSignedIn else { return false }
        self.provider = provider
        return true
    }

    func refresh(
        pairs: [TranslationLanguagePair],
        selectedPair: TranslationLanguagePair,
        provider: TranscriptionProvider? = nil,
        isSignedIn: Bool? = nil
    ) {
        self.pairs = pairs.isEmpty ? [.defaultPair] : pairs
        selectedPairID = self.pairs.contains(selectedPair) ? selectedPair.id : self.pairs[0].id
        if let provider {
            self.provider = provider
        }
        if let isSignedIn {
            self.isSignedIn = isSignedIn
        }
    }

    func presentMeetingSuggestion(_ suggestion: MeetingSuggestion) {
        meetingSuggestion = suggestion
        meetingSuggestionsEnabled = SettingsStorage.shared.meetingSuggestionsEnabled
    }

    @discardableResult
    func selectMeetingSuggestionProvider(_ provider: TranscriptionProvider) -> Bool {
        guard var suggestion = meetingSuggestion,
              provider != .cloud || suggestion.isCloudAvailable
        else { return false }
        suggestion.selectedProvider = provider
        meetingSuggestion = suggestion
        return true
    }

    @discardableResult
    func consumeMeetingSuggestionStart(id: UUID) -> MeetingSuggestion? {
        guard meetingSuggestion?.meeting.id == id else { return nil }
        defer { meetingSuggestion = nil }
        return meetingSuggestion
    }

    func dismissMeetingSuggestion(id: UUID) {
        guard meetingSuggestion?.meeting.id == id else { return }
        meetingSuggestion = nil
    }
}

@MainActor
final class EdgeCommandPanelController: NSObject {
    static let shared = EdgeCommandPanelController()
    static let panelIdentifier = NSUserInterfaceItemIdentifier(
        "ua.com.rmarinsky.diduny.edge-command-panel"
    )

    private weak var appDelegate: AppDelegate?
    private var panel: EdgeCommandPanel?
    private var panelContentView: EdgeCommandPanelContentView?
    private var model: EdgeCommandPanelModel?
    private let meetingRecordingStarter: ((TranscriptionProvider) -> Void)?
    private var collapseTask: Task<Void, Never>?
    private var dock: EdgeCommandPanelDock?
    private var dragCursorOffset: NSPoint?

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

    private func showCollapsed() {
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
        model?.isLiveFeedbackMinimized = false
        model?.isShowingLiveFeedback = true
        position(panel, presentation: .live(mode))
        revealPanelIfConcealed()
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
        model?.isLiveFeedbackMinimized = false
        model?.isShowingLiveFeedback = false
        showCollapsed()
    }

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

    private func perform(_ action: EdgeCommandAction) {
        guard let appDelegate else { return }
        let pair = model?.selectedPair

        switch action {
        case .transcribe:
            if appDelegate.appState.recordingState == .idle {
                guard appDelegate.canStartRecording(kind: .voice) else { showCollapsed(); return }
            }
            appDelegate.toggleRecording()
        case .translate:
            if appDelegate.appState.translationRecordingState == .idle {
                guard appDelegate.canStartRecording(kind: .translation), let pair else { showCollapsed(); return }
                Task { await appDelegate.startTranslationRecording(languagePair: pair) }
            } else {
                appDelegate.toggleTranslationRecording()
            }
        case .meeting:
            if appDelegate.appState.meetingRecordingState == .idle {
                guard appDelegate.canStartRecording(kind: .meeting) else { showCollapsed(); return }
            }
            appDelegate.toggleMeetingRecording()
        case .translateMeeting:
            if appDelegate.appState.meetingTranslationRecordingState == .idle {
                guard appDelegate.canStartRecording(kind: .meetingTranslation),
                      let pair else { showCollapsed(); return }
                Task { await appDelegate.startMeetingTranslationRecording(languagePair: pair) }
            } else {
                appDelegate.toggleMeetingTranslationRecording()
            }
        case .batch:
            appDelegate.batchFilesAndURLs()
            showCollapsed()
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

    private func position(
        _ panel: NSPanel,
        presentation: EdgeCommandPanelPresentation,
        on explicitVisibleFrame: NSRect? = nil
    ) {
        // A live drag owns the frame; phase changes and toasts must not snap
        // the panel back to its dock mid-drag. onDragEnd re-docks and calls
        // position() again after clearing the drag offset.
        guard dragCursorOffset == nil else { return }
        let screen = dock == nil ? activeScreen() : panel.screen ?? activeScreen()
        let visibleFrame = explicitVisibleFrame
            ?? screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let resolvedDock = dock
            ?? EdgeCommandPanelDock(
                rawEdge: SettingsStorage.shared.edgePanelDockEdge,
                offset: SettingsStorage.shared.edgePanelDockOffset
            )
            ?? EdgeCommandPanelDock(edge: .right, offset: visibleFrame.midY)
        dock = resolvedDock
        model?.dockEdge = resolvedDock.edge
        let isExpanded = presentation != .collapsed
        model?.isExpanded = isExpanded
        panelContentView?.setExpanded(isExpanded)
        // Backstop clip: the SwiftUI material's shape mask can be lost by the
        // window server; the layer clip keeps expanded corners rounded no
        // matter what. The collapsed tab keeps its own edge-flush shape.
        panelContentView?.applyCornerMask(
            isExpanded ? EdgeCommandPanelPlacement.expandedCornerRadius : 0
        )

        let frame = EdgeCommandPanelPlacement.frame(
            in: visibleFrame,
            dock: resolvedDock,
            presentation: presentation
        )
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func activeScreen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
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

private final class EdgeCommandPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// The panel is a non-activating panel of a usually-inactive app (the user is
/// dictating into another app). Without accepting first mouse, the initial
/// click is consumed by window-key handling and never reaches the SwiftUI
/// drag gesture or buttons — dragging during recording required a second
/// attempt and Stop/Copy needed a double click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor @preconcurrency dynamic required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class EdgeCommandPanelContentView: NSView {
    private let tabHostingView: NSHostingView<EdgeCommandTabView>
    private let expandedHostingView: NSHostingView<EdgeCommandExpandedView>
    private let onHoverChange: (Bool) -> Void
    private var hoverTrackingArea: NSTrackingArea?

    init(
        tabView: EdgeCommandTabView,
        expandedView: EdgeCommandExpandedView,
        onHoverChange: @escaping (Bool) -> Void
    ) {
        tabHostingView = FirstMouseHostingView(rootView: tabView)
        expandedHostingView = FirstMouseHostingView(rootView: expandedView)
        self.onHoverChange = onHoverChange
        super.init(frame: .zero)

        tabHostingView.sizingOptions = []
        expandedHostingView.sizingOptions = []
        for hostingView: NSView in [tabHostingView, expandedHostingView] {
            hostingView.autoresizingMask = [.width, .height]
            addSubview(hostingView)
        }
        setExpanded(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        tabHostingView.frame = bounds
        expandedHostingView.frame = bounds
    }

    func applyCornerMask(_ radius: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = radius > 0
    }

    func setExpanded(_ expanded: Bool) {
        tabHostingView.isHidden = expanded
        expandedHostingView.isHidden = !expanded
    }

    func updateTabView(_ tabView: EdgeCommandTabView) {
        tabHostingView.rootView = tabView
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange(false)
    }
}

private struct EdgeCommandTabView: View {
    let model: EdgeCommandPanelModel
    let onExpand: () -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void

    var body: some View {
        let edge = model.dockEdge
        Button(action: onExpand) {
            ZStack {
                tabShape
                    .fill(.regularMaterial)
                if model.isLiveFeedbackMinimized {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .shadow(color: .red.opacity(0.45), radius: 4)
                        .accessibilityHidden(true)
                } else {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color("BrandAccentDeep"), Color.pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(
                            width: edge == .left || edge == .right ? 3 : 24,
                            height: edge == .left || edge == .right ? 24 : 3
                        )
                        .shadow(color: Color("BrandAccentDeep").opacity(0.45), radius: 5)
                }
            }
            .overlay(tabShape.stroke(Color("BrandTintBorder"), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .gesture(dragGesture)
        .accessibilityLabel(
            model.isLiveFeedbackMinimized
                ? "Show live recording panel"
                : "Open Diduny quick actions"
        )
        .help(
            model.isLiveFeedbackMinimized
                ? "Click to restore live transcript"
                : "Open Diduny quick actions"
        )
    }

    private var tabShape: UnevenRoundedRectangle {
        switch model.dockEdge {
        case .left:
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 10,
                topTrailingRadius: 10
            )
        case .right:
            UnevenRoundedRectangle(
                topLeadingRadius: 10,
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
        case .top:
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 10,
                topTrailingRadius: 0
            )
        case .bottom:
            UnevenRoundedRectangle(
                topLeadingRadius: 10,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 10
            )
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in onDrag() }
            .onEnded { _ in onDragEnd() }
    }
}

struct EdgeCommandExpandedView: View {
    let model: EdgeCommandPanelModel
    let liveStore: LiveDictationOverlayStore
    let onAction: (EdgeCommandAction) -> Void
    let onProvider: (TranscriptionProvider) -> Void
    let onSignIn: () -> Void
    let onCopy: () -> Void
    let onStop: () -> Void
    let onDismissLive: () -> Void
    let onMinimizeLive: () -> Void
    let onStartMeetingSuggestion: (UUID) -> Void
    let onDismissMeetingSuggestion: (UUID) -> Void
    let onMeetingSuggestionsEnabled: (Bool) -> Void
    let onCollapse: () -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void

    var body: some View {
        ZStack {
            if let suggestion = model.meetingSuggestion {
                MeetingSuggestionView(
                    model: model,
                    suggestion: suggestion,
                    onStart: { onStartMeetingSuggestion(suggestion.meeting.id) },
                    onDismiss: { onDismissMeetingSuggestion(suggestion.meeting.id) },
                    onTrackingChanged: onMeetingSuggestionsEnabled,
                    onDrag: onDrag,
                    onDragEnd: onDragEnd
                )
                .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            } else if model.isShowingLiveFeedback {
                LiveDictationOverlayView(
                    store: liveStore,
                    onCopy: onCopy,
                    onStop: onStop,
                    onDismiss: onDismissLive,
                    onMinimize: onMinimizeLive,
                    onDrag: onDrag,
                    onDragEnd: onDragEnd
                )
                .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            } else {
                commandView
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.isShowingLiveFeedback)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.meetingSuggestion)
    }

    private var commandView: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            header

            providerControl

            if model.showsTranslationControls {
                translationTargetControl(model: model)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(model.availableActions) { action in
                    EdgeCommandActionButton(
                        action: action,
                        meta: actionMeta(action),
                        onAction: { onAction(action) }
                    )
                }
            }

            Button { onAction(.batch) } label: {
                Label("Batch files & URLs", systemImage: EdgeCommandAction.batch.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.plain)
            .help("Process multiple files and URLs")
        }
        .padding(14)
        .background(.regularMaterial, in: panelShape)
        .overlay(panelShape.stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: model.provider)
    }

    private var providerControl: some View {
        HStack(spacing: 7) {
            Text("Provider")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 2) {
                providerButton(.local, title: "Local", icon: "desktopcomputer")
                providerButton(.cloud, title: "Cloud", icon: model.isSignedIn ? "cloud" : "lock.fill")
            }
            .padding(3)
            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if !model.isSignedIn {
                Button("Sign in", action: onSignIn)
                    .font(.system(size: 10.5, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .padding(.horizontal, 7)
                    .frame(height: 26)
                    .background(Color("BrandTintSoft"), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .frame(height: 30)
    }

    private func providerButton(
        _ provider: TranscriptionProvider,
        title: String,
        icon: String
    ) -> some View {
        let selected = model.provider == provider
        return Button { onProvider(provider) } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.horizontal, 6)
            .background(
                selected ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func translationTargetControl(model: EdgeCommandPanelModel) -> some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Text("Translate to")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Picker("Translate to", selection: $model.selectedPairID) {
                ForEach(model.pairs) { pair in
                    Text(languageName(pair.languageB)).tag(pair.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.pink, Color("BrandAccentDeep")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Color("BrandAccentDeep").opacity(0.28), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text("Diduny")
                    .font(.system(size: 13, weight: .bold))
                Text("What do you want to capture?")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: onCollapse) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Hide quick actions")
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .help("Drag to attach to another screen edge")
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: EdgeCommandPanelPlacement.expandedCornerRadius,
            style: .continuous
        )
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in onDrag() }
            .onEnded { _ in onDragEnd() }
    }

    private func actionMeta(_ action: EdgeCommandAction) -> String {
        switch action {
        case .transcribe: String(localized: "Voice → text")
        case .translate: "Voice → \(targetCode)"
        case .meeting: String(localized: "System + mic")
        case .translateMeeting: "Live → \(targetCode)"
        case .batch: ""
        }
    }

    private var targetCode: String {
        model.selectedPair?.languageB.uppercased() ?? "EN"
    }

    private func languageName(_ code: String) -> String {
        SupportedLanguage.language(for: code)?.name ?? code.uppercased()
    }
}

private struct MeetingSuggestionView: View {
    let model: EdgeCommandPanelModel
    let suggestion: MeetingSuggestion
    let onStart: () -> Void
    let onDismiss: () -> Void
    let onTrackingChanged: (Bool) -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "record.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .frame(
                        width: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight,
                        height: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight
                    )
                    .background(Color("BrandTintSoft"), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Looks like a meeting started")
                        .font(.system(size: 15, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(
                            width: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight,
                            height: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close meeting recording suggestion")
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)

            Picker(
                "Meeting transcription provider",
                selection: Binding(
                    get: { model.meetingSuggestion?.selectedProvider ?? suggestion.selectedProvider },
                    set: { model.selectMeetingSuggestionProvider($0) }
                )
            ) {
                Text("Cloud").tag(TranscriptionProvider.cloud)
                Text("Local").tag(TranscriptionProvider.local)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(!suggestion.isCloudAvailable)
            .frame(minHeight: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight)
            .accessibilityLabel("Meeting transcription provider")
            .accessibilityHint(
                suggestion.isCloudAvailable
                    ? "Choose Cloud or Local transcription"
                    : "Cloud is unavailable. Local transcription will be used."
            )

            Label(suggestion.processingMode.label, systemImage: suggestion.processingMode.icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            Toggle(
                "Continue tracking meetings and suggesting recordings",
                isOn: $model.meetingSuggestionsEnabled
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 11.5))
            .frame(
                minHeight: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight,
                alignment: .leading
            )
            .onChange(of: model.meetingSuggestionsEnabled) { _, enabled in
                onTrackingChanged(enabled)
            }
            .accessibilityLabel("Continue tracking meetings and suggesting recordings")

            HStack(spacing: 8) {
                Button(action: onDismiss) {
                    Text("Not now")
                        .frame(
                            maxWidth: .infinity,
                            minHeight: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight
                        )
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Not now")

                Button(action: onStart) {
                    Text("Start recording")
                        .frame(
                            maxWidth: .infinity,
                            minHeight: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight
                        )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Start recording and transcription")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: panelShape)
        .overlay(panelShape.stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting recording suggestion")
    }

    private var message: String {
        String(
            format: String(
                localized: "Start recording and transcription in %@ so you can return to the materials after the meeting?"
            ),
            suggestion.meeting.client.displayName
        )
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: EdgeCommandPanelPlacement.expandedCornerRadius,
            style: .continuous
        )
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in onDrag() }
            .onEnded { _ in onDragEnd() }
    }
}

private struct EdgeCommandActionButton: View {
    let action: EdgeCommandAction
    let meta: String
    let onAction: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let highlighted = isHovered || isFocused
        Button(action: onAction) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: action.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .frame(width: 24, height: 24)
                    .background(Color("BrandTintSoft"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(action.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .background(
            highlighted ? Color("BrandAccentDeep").opacity(0.11) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(highlighted ? Color("BrandTintBorder") : Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .offset(y: highlighted ? -1 : 0)
        .shadow(color: highlighted ? Color("BrandAccentDeep").opacity(0.14) : .clear, radius: 8, y: 4)
        .animation(.easeOut(duration: 0.15), value: highlighted)
        .onHover { isHovered = $0 }
        .help(action.usesLanguagePair ? "Uses the selected translation language" : action.title)
    }
}
