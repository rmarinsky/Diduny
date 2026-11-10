import AppKit
import ApplicationServices

/// Chromium and Electron build their accessibility tree only when an assistive client asks, so
/// without this their text fields give no caret geometry. Other dictation and accessibility tools
/// do the same: set `AXManualAccessibility` on the app element (Electron's documented switch),
/// falling back to `AXEnhancedUserInterface` for Chromium browsers only, since that flag breaks
/// window animations in some apps.
///
/// The tree is left on for the app's lifetime: it costs that app some CPU while on, but turning it
/// off after each dictation would make the app rebuild the whole tree at the next Stop, which costs
/// more and leaves the first query empty. Done at a recording's start and again at Stop (cached),
/// off the main thread, never per keystroke.
enum ChromiumAccessibility {
    enum Kind: Equatable {
        case electron
        case chromium
        case other
    }

    static let electronBundleIDs: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.hnc.Discord",
        "notion.id",
        "md.obsidian",
        "com.figma.Desktop"
    ]

    static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]

    /// Known bundle ids first, then the bundle's `Electron Framework.framework`.
    static func kind(bundleID: String?, hasElectronFramework: Bool) -> Kind {
        if let bundleID {
            if electronBundleIDs.contains(bundleID) { return .electron }
            if chromiumBundleIDs.contains(bundleID) { return .chromium }
        }
        return hasElectronFramework ? .electron : .other
    }

    /// Which flag to try next: the manual switch first; the enhanced UI flag only for Chromium.
    static func attributes(for kind: Kind) -> [String] {
        switch kind {
        case .electron: ["AXManualAccessibility"]
        case .chromium: ["AXManualAccessibility", "AXEnhancedUserInterface"]
        case .other: []
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var kinds: [String: Kind] = [:]
    nonisolated(unsafe) private static var enabledPIDs: Set<pid_t> = []

    /// Turns the frontmost app's tree on if it is Chromium or Electron. Blocking; call off main.
    static func prepareFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        prepare(pid: app.processIdentifier, bundleID: app.bundleIdentifier, bundleURL: app.bundleURL)
    }

    static func prepare(pid: pid_t, bundleID: String?, bundleURL: URL?) {
        let key = bundleID ?? bundleURL?.path ?? "\(pid)"
        lock.lock()
        let cached = kinds[key]
        let alreadyOn = enabledPIDs.contains(pid)
        lock.unlock()
        guard !alreadyOn else { return }

        let kind = cached ?? kind(bundleID: bundleID, hasElectronFramework: hasElectronFramework(bundleURL))
        lock.lock()
        kinds[key] = kind
        lock.unlock()
        guard kind != .other else { return }

        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        for attribute in attributes(for: kind)
            where AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue) == .success
        {
            lock.lock()
            enabledPIDs.insert(pid)
            lock.unlock()
            return
        }
    }

    private static func hasElectronFramework(_ bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }
}
