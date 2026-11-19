import Foundation
import Observation

/// What the silent update is doing, for Overview, About and the floating panel. `UpdaterManager` writes it.
@MainActor
@Observable
final class UpdateStatus {
    enum Phase: Equatable {
        case idle
        case downloading(version: String)
        /// Downloaded and prepared. The app restarts by itself when no recording runs.
        case waiting(version: String)
        case restarting
    }

    static let shared = UpdateStatus()

    var phase: Phase = .idle
    /// True while a recording or transcription runs. Only kept current while `phase` is `.waiting`.
    var isBusy = false
    @ObservationIgnored var restartNow: (() -> Void)?

    var canRestart: Bool {
        if case .waiting = phase { return !isBusy }
        return false
    }

    func restart() {
        guard canRestart else { return }
        restartNow?()
    }

    // MARK: - Texts

    /// Overview card first line. Nil hides the card.
    var cardTitle: String? {
        switch phase {
        case .idle: nil
        case let .downloading(version): String(localized: "Downloading Diduny \(version)")
        case let .waiting(version): String(localized: "Diduny \(version) is ready")
        case .restarting: String(localized: "Restarting Diduny...")
        }
    }

    var cardDetail: String? {
        switch phase {
        case .idle, .restarting: nil
        case .downloading: String(localized: "In the background. You can keep working.")
        case .waiting: isBusy
            ? String(localized: "Finish the recording first.")
            : String(localized: "Downloaded in the background. Restarting takes a few seconds.")
        }
    }

    /// Floating panel line. Nil hides the row.
    var panelText: String? {
        switch phase {
        case .idle: nil
        case let .downloading(version): String(localized: "Downloading Diduny \(version) in the background.")
        case let .waiting(version): String(localized: "Diduny \(version) is downloaded.")
        case .restarting: String(localized: "Restarting Diduny...")
        }
    }

    /// About headline while an update is in flight. Nil keeps About's own check.
    var aboutHeadline: String? {
        switch phase {
        case .idle: nil
        case .downloading: String(localized: "Downloading the update")
        case .waiting, .restarting: String(localized: "Update downloaded")
        }
    }

    var aboutButtonTitle: String? {
        switch phase {
        case .idle: nil
        case .downloading: String(localized: "Downloading...")
        case .waiting: String(localized: "Restart to update")
        case .restarting: String(localized: "Restarting...")
        }
    }

    var showsRestartButton: Bool {
        if case .waiting = phase { return true }
        return false
    }

    #if TEST_BUILD
        /// `--ui-testing-update=downloading|waiting|busy|restarting`, version 1.15.0.
        func applyUITestingArgument(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
            guard let arg = arguments.first(where: { $0.hasPrefix("--ui-testing-update=") }) else { return }
            switch arg.dropFirst("--ui-testing-update=".count) {
            case "downloading": phase = .downloading(version: "1.15.0")
            case "waiting": phase = .waiting(version: "1.15.0")
            case "busy": phase = .waiting(version: "1.15.0"); isBusy = true
            case "restarting": phase = .restarting
            default: break
            }
            restartNow = { [weak self] in self?.phase = .restarting }
        }
    #endif
}
