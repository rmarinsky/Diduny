import AppKit
import ApplicationServices

// AX references are used only by the serialized worker, never concurrently.
struct BrowserTarget: @unchecked Sendable {
    let window: AXUIElement
    let pid: pid_t
    let url: URL
}

struct BrowserReadResult: Sendable {
    let target: BrowserTarget
    let snapshot: CalendarSnapshot
    let inspectedNodes: Int
    let eventCandidates: Int
    let incomplete: Bool
}

final class BrowserReader {
    let access: ReadAccess
    private var incompleteAttributes = false
    init(access: ReadAccess) { self.access = access }
    enum Failure: Error, LocalizedError {
        case permission, closed, noPage, changed
        var errorDescription: String? {
            switch self {
            case .permission: return String(localized: "Allow Diduny Accessibility access in System Settings, then retry reading.")
            case .closed: return String(localized: "Open the selected browser and select its calendar tab.")
            case .noPage: return String(localized: "Could not read the active page. Open the calendar in the selected browser.")
            case .changed: return String(localized: "The named calendar window is not open. Restore that tab, or disconnect and connect the window again.")
            }
        }
    }

    func read(bundleID: String, approved: Bool, target: BrowserTarget? = nil, profileName: String? = nil, saved: SavedConnection? = nil, adoptUnnamed: Bool = false) throws -> BrowserReadResult {
        guard approved else { throw CalendarReadError.consentRequired }
        try access.check()
        guard AXIsProcessTrusted() else { throw Failure.permission }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { throw Failure.closed }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
        let window: AXUIElement
        var adoptedUnnamed = false
        if let target {
            guard target.pid == app.processIdentifier,
                  let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement],
                  windows.contains(where: { CFEqual($0, target.window) }) else { throw Failure.changed }
            window = target.window
        } else if let saved {
            let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let chrome = NativeProfiles(access: access)
            var candidates: [(AXUIElement, URL, String?, String)] = []
            for candidate in windows {
                let title = string(candidate, kAXTitleAttribute) ?? ""
                guard SavedConnection.matchesWindowTitle(title, name: saved.windowName),
                      let page = findPage(candidate), let url = pageURL(page) else { continue }
                candidates.append((candidate, url, chrome.profile(in: candidate, names: [saved.profileName]), title))
            }
            if let index = saved.matchingCandidate(urls: candidates.map { $0.1 }, profiles: candidates.map { $0.2 }, windowTitles: candidates.map { $0.3 }) {
                window = candidates[index].0
            } else if adoptUnnamed, let adopted = unnamedCalendar(windows, saved: saved, chrome: chrome) {
                window = adopted
                adoptedUnnamed = true
            } else {
                throw Failure.changed
            }
        } else {
            guard let selected = element(root, kAXFocusedWindowAttribute) ?? element(root, kAXMainWindowAttribute) else { throw Failure.noPage }
            window = selected
        }
        if let expected = saved?.profileName ?? profileName, !profileAllows(window, expected: expected, required: saved == nil) {
            throw NativeProfiles.Failure.mismatch
        }
        if let saved, !adoptedUnnamed {
            try saved.validate()
            guard SavedConnection.matchesWindowTitle(string(window, kAXTitleAttribute) ?? "", name: saved.windowName) else { throw Failure.changed }
        }
        // Discover only the selected window's web area. Do not read text before validating its URL.
        guard let page = findPage(window), let url = pageURL(page) else { throw Failure.noPage }
        guard CalendarPage.provider(for: url) != nil else { throw CalendarReadError.wrongPage }
        if let target, !SavedConnection.sameCalendar(target.url, url) { throw Failure.changed }
        if let saved, !SavedConnection.sameCalendar(saved.calendarURL, url) { throw Failure.changed }
        var stack: [(AXUIElement, Int)] = [(page, 0)]
        var nodes: [PageNode] = []
        var count = 0, candidates = 0, incomplete = false
        var walkError: Error?
        var stoppedEarly = false
        while let (node, depth) = stack.popLast() {
            do { try access.check() } catch is CancellationError { throw CancellationError() } catch {
                walkError = error
                incomplete = true
                stoppedEarly = true
                break
            }
            guard count < 12000 else { incomplete = true; break }
            count += 1
            let role = string(node, kAXRoleAttribute) ?? ""
            // Embedded documents are excluded: their contents are not the approved top-level page.
            if role == "AXWebArea", !CFEqual(node, page) { continue }
            if role == kAXButtonRole || role == "AXLink" {
                // A missing URL here is the read budget running out, not a navigation. Keep the rows already collected.
                guard let live = pageURL(page) else { incomplete = true; stoppedEarly = true; break }
                guard live == url else { throw Failure.changed }
                let label = string(node, kAXDescriptionAttribute) ?? string(node, kAXTitleAttribute) ?? ""
                if role == kAXButtonRole, label.contains(":") { candidates += 1 }
                nodes.append(PageNode(role: role, label: label, url: role == "AXLink" ? pageURL(node) : nil))
            }
            if depth >= 60 { incomplete = true; continue }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        if nodes.isEmpty, let walkError { throw walkError }
        if !stoppedEarly {
            guard let currentPage = findPage(window), CFEqual(currentPage, page), pageURL(currentPage) == url else { throw Failure.changed }
            if let expected = saved?.profileName ?? profileName, !profileAllows(window, expected: expected, required: saved == nil) {
                throw Failure.changed
            }
            try access.check()
        }
        let snapshot = try CalendarExtraction.read(approved: approved, pageURL: url) { nodes }
        return BrowserReadResult(target: BrowserTarget(window: window, pid: app.processIdentifier, url: url), snapshot: snapshot, inspectedNodes: count, eventCandidates: candidates, incomplete: incomplete || incompleteAttributes)
    }

    /// The calendar page we just opened does not have the saved window name yet. Use it only when it is the only match.
    private func unnamedCalendar(_ windows: [AXUIElement], saved: SavedConnection, chrome: NativeProfiles) -> AXUIElement? {
        var matches: [AXUIElement] = []
        for candidate in windows {
            guard let page = findPage(candidate), let url = pageURL(page), SavedConnection.sameCalendar(saved.calendarURL, url) else { continue }
            let profile = chrome.profile(in: candidate, names: [saved.profileName])
            guard profile == nil || profile == saved.profileName else { continue }
            matches.append(candidate)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// A restored window is already named. An unreadable profile control does not make it a different window.
    /// The first connect still has to see the chosen profile.
    private func profileAllows(_ window: AXUIElement, expected: String, required: Bool) -> Bool {
        let seen = NativeProfiles(access: access).profile(in: window, names: [expected])
        if seen == expected { return true }
        return seen == nil && !required
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        guard (try? access.check()) != nil else { return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard status == .success else {
            if status != .noValue && status != .attributeUnsupported { incompleteAttributes = true }
            return nil
        }
        return value
    }
    private func string(_ node: AXUIElement, _ key: String) -> String? {
        guard let value = attribute(node, key) as? String, !value.isEmpty else { return nil }
        return value
    }
    private func element(_ node: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(node, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func pageURL(_ node: AXUIElement) -> URL? {
        guard let value = attribute(node, kAXURLAttribute) else { return nil }
        if let url = value as? URL { return url }
        if let text = value as? String { return URL(string: text) }
        return nil
    }
    private func findPage(_ window: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(window, 0)], cursor = 0
        while cursor < queue.count, cursor < 400 {
            guard (try? access.check()) != nil else { return nil }
            let (node, depth) = queue[cursor]; cursor += 1
            if string(node, kAXRoleAttribute) == "AXWebArea" { return node }
            if depth < 15, let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return nil
    }
}
