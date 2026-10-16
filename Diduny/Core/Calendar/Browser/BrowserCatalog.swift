import AppKit

struct InstalledBrowser: Identifiable, Sendable {
    let id: String
    let name: String
    let url: URL
    let profiles: [BrowserProfile]

    /// Same OS discovery and Chromium metadata pattern as AppCat. No credential stores.
    static func discover() -> [InstalledBrowser] {
        let paths = ["com.google.Chrome": "Google/Chrome", "com.microsoft.edgemac": "Microsoft Edge",
                     "com.brave.Browser": "BraveSoftware/Brave-Browser", "org.chromium.Chromium": "Chromium",
                     "com.vivaldi.Vivaldi": "Vivaldi", "com.google.Chrome.canary": "Google/Chrome Canary"]
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!).compactMap { url in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !id.hasPrefix("ua.com.rmarinsky.appcat"), id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { return nil }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
            var profiles: [BrowserProfile] = []
            if let path = paths[id], let data = try? Data(contentsOf: support.appendingPathComponent(path).appendingPathComponent("Local State")) {
                profiles = BrowserProfile.chromium(data: data).filter {
                    FileManager.default.fileExists(atPath: support.appendingPathComponent(path).appendingPathComponent($0.id).path)
                }
            }
            let native = (try? NativeProfiles().profiles(bundleID: id)) ?? []
            if !native.isEmpty { profiles = native }
            return InstalledBrowser(id: id, name: name, url: url, profiles: profiles)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @MainActor func openCalendar(_ url: URL, profile: String) throws {
        if profile.hasPrefix("menu:") {
            throw NativeProfiles.Failure.mismatch // Native selection is asynchronous in BrowserCalendarConnection.
        } else if !profile.isEmpty {
            guard profiles.contains(where: { $0.id == profile }), let executable = Bundle(url: self.url)?.executableURL else { throw CocoaError(.fileNoSuchFile) }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--profile-directory=\(profile)", "--new-window", url.absoluteString]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: self.url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
