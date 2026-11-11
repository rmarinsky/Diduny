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

    init(isBusy: @escaping () -> Bool) {
        self.isBusy = isBusy
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
        let install = { [weak self] in
            guard let self, !self.isBusy() else { return false }
            self.pendingInstallTimer?.invalidate()
            self.pendingInstallTimer = nil
            immediateInstallHandler()
            return true
        }
        if !install() {
            pendingInstallTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                MainActor.assumeIsolated { _ = install() }
            }
        }
        return true
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
