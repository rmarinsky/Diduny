import AppKit
import Combine
import Sparkle

@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    private var updaterController: SPUStandardUpdaterController!

    @Published var canCheckForUpdates = false

    /// True while a recording or transcription runs; a silent update waits until it is false.
    private let isBusy: () -> Bool
    private var pendingInstallTimer: Timer?
    private var busyRefreshTimer: Timer?
    private let status: UpdateStatus

    init(isBusy: @escaping () -> Bool, status: UpdateStatus = .shared) {
        self.isBusy = isBusy
        self.status = status
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        updaterController.startUpdater()
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterManager: @preconcurrency SPUUpdaterDelegate {
    /// A silently downloaded update would otherwise wait for the user to quit a menu bar app.
    /// Install and relaunch right away, but never during a recording or transcription.
    func updater(
        _: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        Log.app.info("Update \(item.displayVersionString) downloaded; installing when idle")
        pendingInstallTimer?.invalidate()
        busyRefreshTimer?.invalidate()
        status.phase = .waiting(version: item.displayVersionString)
        status.isBusy = isBusy()
        let install = { [weak self] in
            guard let self, !self.isBusy() else { return false }
            self.pendingInstallTimer?.invalidate()
            self.pendingInstallTimer = nil
            self.busyRefreshTimer?.invalidate()
            self.busyRefreshTimer = nil
            self.status.phase = .restarting
            immediateInstallHandler()
            return true
        }
        // "Restart to update" installs now instead of at the next retry.
        status.restartNow = { _ = install() }
        if !install() {
            pendingInstallTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                MainActor.assumeIsolated { _ = install() }
            }
            // Keeps the button's enabled state current while the update waits.
            busyRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.status.isBusy = self.isBusy()
                }
            }
        }
        return true
    }

    func updater(_: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with _: NSMutableURLRequest) {
        status.phase = .downloading(version: item.displayVersionString)
    }

    func updater(_: SPUUpdater, failedToDownloadUpdate _: SUAppcastItem, error _: any Error) {
        if case .downloading = status.phase { status.phase = .idle }
    }

    func userDidCancelDownload(_: SPUUpdater) {
        if case .downloading = status.phase { status.phase = .idle }
    }

    func updater(_: SPUUpdater, didAbortWithError _: any Error) {
        if case .downloading = status.phase { status.phase = .idle }
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdaterManager: @preconcurrency SPUStandardUserDriverDelegate {
    /// Show the app in the dock while the update window is visible so it can come to front.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillShowModalAlert() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate _: SUAppcastItem) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Restore accessory (menu-bar-only) mode after update UI closes
        MainWindowController.shared.refreshActivationPolicy()
    }
}
