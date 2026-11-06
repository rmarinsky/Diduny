@testable import Diduny
import AppKit
import SwiftUI
import Testing

/// Settings > General (WP-52, test-plan T5-GE-14 and the page render).
@MainActor
struct GeneralSettingsTests {
    /// The action takes no storage, so it cannot write `userDeclinedScreenRecording`.
    @Test("Ask again calls the Screen Recording request path once")
    func askAgainCallsRequestPath() async {
        var calls = 0
        await GeneralSettingsActions.askAgainForScreenRecording { calls += 1; return false }
        #expect(calls == 1)
    }

    @Test("Surface tiles map to the stored recording feedback surface")
    func surfaceMapping() {
        #expect(GeneralSettingsActions.surface(for: .floatingPanel) == .compactPanel)
        #expect(GeneralSettingsActions.surface(for: .dynamicNotch) == .notch)
        #expect(GeneralSettingsActions.previewKind(for: .compactPanel) == .floatingPanel)
        #expect(GeneralSettingsActions.previewKind(for: .notch) == .dynamicNotch)
    }

    @Test("Surface preview tile measures 140 x 105")
    func previewTileSize() {
        let size = RetinaHost.fittingSize(SurfacePreviewTile(kind: .floatingPanel, isSelected: true) {})
        #expect(abs(size.width - 140) <= 1)
        #expect(abs(size.height - 105) <= 1)
    }

    enum Appearance: String, CaseIterable, Sendable { case light, dark }

    /// Page capture for the designer (same output folder as `ComponentRenderTests`).
    @Test("General page renders to a PNG", arguments: Appearance.allCases)
    func renderPage(_ appearance: Appearance) throws {
        let page = GeneralSettingsView().frame(width: 757, height: 1100)
        let bitmap = try #require(RetinaHost.render(page, appearance: NSAppearance(named: appearance == .light ? .aqua : .darkAqua)))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(!png.isEmpty)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("components", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent("generalPage-\(appearance.rawValue).png"))
        }
    }
}
