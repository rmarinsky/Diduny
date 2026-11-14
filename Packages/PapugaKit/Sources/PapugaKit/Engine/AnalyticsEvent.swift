import Foundation

enum AnalyticsValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

struct AnalyticsEvent: Codable {
    let id: String
    let timestamp: Date
    let app: String
    let appVersion: String
    let build: String
    let platform: String
    let kind: String
    let frontmostBundleID: String?
    let inputLayout: String?
    let properties: [String: AnalyticsValue]

    enum CodingKeys: String, CodingKey {
        case id, timestamp, app, kind, properties
        case appVersion = "app_version"
        case build, platform
        case frontmostBundleID = "frontmost_bundle_id"
        case inputLayout = "input_layout"
    }

    init(
        kind: String,
        frontmostBundleID: String? = nil,
        inputLayout: String? = nil,
        properties: [String: AnalyticsValue] = [:],
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
        build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    ) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.app = "papuga"
        self.appVersion = appVersion
        self.build = build
        self.platform = "macos"
        self.kind = kind
        self.frontmostBundleID = frontmostBundleID
        self.inputLayout = inputLayout
        self.properties = properties
    }
}

enum AnalyticsKind {
    static let autoFixApplied = "auto_fix_applied"
    static let autoFixSkipped = "auto_fix_skipped"
    static let autoFixProposalResolved = "auto_fix_proposal_resolved"
    static let autoFixUndone = "auto_fix_undone"
    static let autoFixLayoutOnly = "auto_fix_layout_only"
    static let autoFixRetypedAfterFix = "auto_fix_retyped_after_fix"
    static let manualSwitchCompleted = "manual_switch_completed"
    static let manualSwitchAborted = "manual_switch_aborted"
    static let settingChanged = "setting_changed"
}
