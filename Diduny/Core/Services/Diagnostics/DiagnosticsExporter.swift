import AppKit
import Foundation

/// Builds a zip the user can send to support: the rolling diagnostics log plus a
/// summary of versions and settings. No audio, transcripts, titles, file names,
/// emails, keys or tokens go in; the summary is an explicit allowlist.
@MainActor
enum DiagnosticsExporter {
    static func defaultFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "Diduny-diagnostics-\(formatter.string(from: now)).zip"
    }

    static func summary(appDelegate: AppDelegate?) -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let library = RecordingsLibraryStorage.shared.recordings
        var engines: [String: String] = [:]
        if let appDelegate {
            for job in STTJob.allCases { engines[job.rawValue] = appDelegate.analyticsEngine(for: job) }
        }
        return [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": IncidentReporter.appVersion,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "macOS": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "arch": AppLaunchTracker.hardwareArchitecture(),
            "locale": Locale.current.identifier,
            "signedIn": AuthService.shared.isLoggedIn,
            "statisticsSharing": AnalyticsService.shared.enabled,
            "featureUsageSharing": SettingsStorage.shared.shareFeatureUsage,
            "enginesByJob": engines,
            "recordings": [
                "total": library.count,
                "byType": Dictionary(grouping: library, by: { String(describing: $0.type) }).mapValues(\.count),
            ],
        ]
    }

    /// Writes `<destination>` as a zip of the diagnostics files and `summary.json`. The zip is built
    /// off the main actor; an existing file at `destination` is replaced only once the new zip is ready.
    static func makeArchive(log: DiagnosticLog, summary: [String: Any], destination: URL) async throws {
        log.flush()
        let files = log.files()
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try await Task.detached(priority: .userInitiated) {
            try writeArchive(files: files, summary: data, destination: destination)
        }.value
    }

    nonisolated static func writeArchive(
        files: [URL], summary: Data, destination: URL, ditto dittoPath: String = "/usr/bin/ditto"
    ) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Diduny-diagnostics-\(UUID().uuidString)")
        let folder = staging.appendingPathComponent(destination.deletingPathExtension().lastPathComponent)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for file in files {
            try fm.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        }
        try summary.write(to: folder.appendingPathComponent("summary.json"))
        let zip = staging.appendingPathComponent("archive.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: dittoPath)
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: zip)
        } else {
            try fm.moveItem(at: zip, to: destination)
        }
    }

    /// Asks where to save, writes the zip and shows it in Finder.
    static func exportInteractively(appDelegate: AppDelegate?) {
        FeatureUsageCounter.shared.record(.exportDiagnostics, via: .menu)
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Diagnostics")
        panel.message = String(localized: "Contains app events and errors only: no audio, text, file names or keys.")
        panel.nameFieldStringValue = defaultFileName()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DiagnosticLog.shared.record(.diagnosticsExported)
        let summary = summary(appDelegate: appDelegate)
        Task {
            do {
                try await makeArchive(log: .shared, summary: summary, destination: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Could not export diagnostics")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
