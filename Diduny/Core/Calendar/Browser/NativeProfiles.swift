import AppKit
import ApplicationServices

/// Only browser chrome/menu metadata is inspected here; web content is excluded.
final class NativeProfiles {
    let access: ReadAccess
    init(access: ReadAccess = ReadAccess()) { self.access = access }
    enum Failure: Error, LocalizedError {
        case unavailable, mismatch
        case naming(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Профілі недоступні. Відкрийте браузер, перевірте Accessibility і оновіть список."
            case .mismatch: return "Не вдалося підтвердити вибраний профіль. Відкрийте потрібне вікно браузера й повторіть дію."
            case .naming(let stage): return "Браузер не підтвердив назву вікна (\(stage)). Збережене підключення не створено."
            }
        }
    }
    func root(_ bundleID: String) throws -> AXUIElement {
        try access.check()
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { throw Failure.unavailable }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        return root
    }
    func value(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        guard (try? access.check()) != nil else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else { return nil }
        return value
    }
    func text(_ node: AXUIElement, _ key: String) -> String { value(node, key) as? String ?? "" }
    func label(_ node: AXUIElement) -> String {
        let title = text(node, kAXTitleAttribute)
        return title.isEmpty ? text(node, kAXDescriptionAttribute) : title
    }
    func element(_ node: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = value(node, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    func nodes(_ root: AXUIElement, max: Int = 2000) -> [AXUIElement] {
        var stack = [(root, 0)], result: [AXUIElement] = []
        while let (node, depth) = stack.popLast(), result.count < max, (try? access.check()) != nil {
            if text(node, kAXRoleAttribute) == "AXWebArea" { continue }
            result.append(node)
            if depth < 20, let children = value(node, kAXChildrenAttribute) as? [AXUIElement] { stack.append(contentsOf: children.reversed().map { ($0, depth + 1) }) }
        }
        return result
    }
    func menuItems(_ root: AXUIElement) -> [AXUIElement] {
        guard let menu = element(root, kAXMenuBarAttribute) else { return [] }
        return nodes(menu)
    }
    func profiles(bundleID: String) throws -> [BrowserProfile] {
        let root = try root(bundleID)
        let items = menuItems(root).map { (text($0, kAXTitleAttribute), text($0, kAXIdentifierAttribute)) }
        try access.check()
        return BrowserProfile.nativeMenu(items: items)
    }
    func profile(in window: AXUIElement, names: [String]) -> String? {
        let toolbars = nodes(window, max: 500).filter { text($0, kAXRoleAttribute) == kAXToolbarRole }
        let matches = toolbars.compactMap { toolbar -> String? in
            let children = value(toolbar, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let controls = children.map { node -> (String, String) in
                let title = text(node, kAXTitleAttribute)
                return (text(node, kAXRoleAttribute), title.isEmpty ? text(node, kAXDescriptionAttribute) : title)
            }
            return BrowserProfile.avatar(in: controls, names: names)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func select(bundleID: String, profile: String) throws {
        let root = try root(bundleID)
        let matches = menuItems(root).filter { text($0, kAXIdentifierAttribute) == "switchToProfileFromMenu:" && text($0, kAXTitleAttribute) == profile }
        guard matches.count == 1 else { throw Failure.unavailable }
        try access.check()
        guard AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success else { throw Failure.mismatch }
        for _ in 0..<30 {
            try access.check()
            if let focused = element(root, kAXFocusedWindowAttribute), self.profile(in: focused, names: [profile]) == profile { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw Failure.mismatch
    }
    func nameWindow(bundleID: String, window: AXUIElement, name: String) throws {
        let root = try root(bundleID)
        guard let focused = element(root, kAXFocusedWindowAttribute), CFEqual(focused, window) else { throw Failure.mismatch }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              app.activate(options: []) else { throw Failure.naming("активація") }
        // Activation is asynchronous. Dispatching a menu command before it completes
        // can report AX success without opening the browser's sheet.
        for _ in 0..<30 {
            try access.check()
            if app.isActive { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard app.isActive, let activeWindow = element(root, kAXFocusedWindowAttribute),
              CFEqual(activeWindow, window) else { throw Failure.mismatch }
        let commands = menuItems(root).filter { ["name window...", "назвати вікно..."].contains(label($0).lowercased().replacingOccurrences(of: "…", with: "...")) }
        guard commands.count == 1 else { throw Failure.naming("команда: \(commands.count)") }
        try access.check()
        guard AXUIElementPerformAction(commands[0], kAXPressAction as CFString) == .success else { throw Failure.naming("дія") }
        for _ in 0..<30 {
            try access.check()
            let attachedSheets = value(window, "AXSheets") as? [AXUIElement] ?? []
            let candidates = nodes(window) + attachedSheets.filter { sheet in !nodes(window).contains { CFEqual($0, sheet) } }
            // The sheet must belong to the approved window, not another window in the app.
            let sheets = candidates.filter { text($0, kAXRoleAttribute) == kAXSheetRole && ["Name this window", "Назвати це вікно"].contains(label($0)) }
            guard sheets.count < 2 else { throw Failure.naming("дія") }
            if let sheet = sheets.first {
                let controls = nodes(sheet)
                let fields = controls.filter { text($0, kAXRoleAttribute) == kAXTextFieldRole }
                let buttons = controls.filter { text($0, kAXRoleAttribute) == kAXButtonRole && label($0) == "OK" }
                guard fields.count == 1, buttons.count == 1 else { throw Failure.naming("дія") }
                try access.check()
                guard AXUIElementSetAttributeValue(fields[0], kAXValueAttribute as CFString, name as CFString) == .success else { throw Failure.naming("дія") }
                try access.check()
                guard AXUIElementPerformAction(buttons[0], kAXPressAction as CFString) == .success else { throw Failure.naming("дія") }
                for _ in 0..<20 {
                    try access.check()
                    if SavedConnection.matchesWindowTitle(text(window, kAXTitleAttribute), name: name) { return }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                throw Failure.naming("назву не підтверджено")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw Failure.naming("назву не підтверджено")
    }
}
