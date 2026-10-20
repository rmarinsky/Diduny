import Foundation
public struct BrowserProfile: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
    public static func chromium(data: Data) -> [BrowserProfile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let entries = profile["info_cache"] as? [String: [String: Any]] else { return [] }
        return entries.compactMap { id, value in
            guard !id.isEmpty, !id.contains("/"), !id.contains("\\"), id != ".", id != "..",
                  value["is_omitted_from_profile_list"] as? Bool != true else { return nil }
            return BrowserProfile(id: id, name: value["name"] as? String ?? id)
        }.sorted { $0.id < $1.id }
    }
}

extension BrowserProfile {
    public static func nativeMenu(items: [(String, String)]) -> [BrowserProfile] {
        let names = items.filter { $0.1 == "switchToProfileFromMenu:" && !$0.0.isEmpty }.map { $0.0 }
        return names.filter { name in names.filter { $0 == name }.count == 1 }.map { BrowserProfile(id: "menu:" + $0, name: $0) }
    }
    public static func observed(in buttons: [String], names: [String]) -> String? {
        let matches = Set(names.filter { name in buttons.contains(name) || buttons.contains(name + " Profile") })
        return matches.count == 1 ? matches.first : nil
    }
}

extension BrowserProfile {
    public static func avatar(in controls: [(String, String)], names: [String]) -> String? {
        let anchors = controls.indices.filter {
            (controls[$0].0 == "AXPopUpButton" && controls[$0].1 == "Chrome") ||
            (controls[$0].0 == "AXButton" && controls[$0].1 == "Settings and more")
        }
        guard anchors.count == 1, let index = anchors.first, index > 0,
              controls[index - 1].0 == "AXButton" else { return nil }
        return observed(in: [controls[index - 1].1], names: names)
    }
}
