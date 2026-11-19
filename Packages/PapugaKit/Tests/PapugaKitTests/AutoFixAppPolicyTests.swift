import XCTest
@testable import PapugaKit

final class AutoFixAppPolicyTests: XCTestCase {
    func test_all_apps_default_to_auto_mutate() {
        // No hardcoded per-app exceptions anymore: editors, IDEs, terminals, and native apps all
        // auto-mutate by default. Exclusions are user-driven (blocklist / overrides).
        for bundleID in [
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92", // Cursor
            "com.jetbrains.intellij",
            "com.openai.codex",
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "com.apple.Notes"
        ] {
            XCTAssertEqual(
                AutoFixAppPolicyResolver.defaultPolicy(for: bundleID),
                .autoMutate,
                "\(bundleID) should default to auto-mutate"
            )
        }
    }

    func test_user_override_takes_precedence_over_default() {
        let overrides = ["com.apple.Terminal": AutoFixAppPolicy.disabled.rawValue]

        XCTAssertEqual(AutoFixAppPolicyResolver.policy(for: "com.apple.Terminal", overrides: overrides), .disabled)
        // An app without an override still uses the auto-mutate default.
        XCTAssertEqual(AutoFixAppPolicyResolver.policy(for: "com.apple.Notes", overrides: overrides), .autoMutate)
    }

    func test_missing_bundle_id_defaults_to_suggest_only() {
        XCTAssertEqual(AutoFixAppPolicyResolver.policy(for: nil), .suggestOnly)
        XCTAssertEqual(AutoFixAppPolicyResolver.policy(for: ""), .suggestOnly)
    }
}
