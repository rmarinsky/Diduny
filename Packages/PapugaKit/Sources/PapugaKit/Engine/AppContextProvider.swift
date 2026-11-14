import AppKit
import Foundation

enum AppContextProvider {
    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    static func runningAppCandidates() -> [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier,
                  let name = app.localizedName,
                  app.activationPolicy == .regular else {
                return nil
            }
            return (id, name)
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Best-effort human name for a bundle ID, even if the app isn't running:
    /// running localizedName → installed app's display name → last dotted component.
    static func displayName(forBundleID bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return running
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.split(separator: ".").last.map { String($0).capitalized } ?? bundleID
    }

    /// The installed app's Finder icon for a bundle ID, or nil if it can't be located.
    static func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
