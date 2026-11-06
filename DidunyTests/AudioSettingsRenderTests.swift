import AppKit
@testable import Diduny
import SwiftUI
import Testing

/// Settings > Audio page capture in light and dark (implementation-plan WP-54). No pixel assertion;
/// PNGs go to `$SCREENSHOT_DIR/pages` for the designer's review against prototype v9.
@MainActor
struct AudioSettingsRenderTests {
    private static let outputDirectory: URL? = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]
        .map { URL(fileURLWithPath: $0).appendingPathComponent("pages", isDirectory: true) }

    @Test("Audio page renders to a PNG", arguments: ["light", "dark"])
    func render(_ appearance: String) throws {
        let page = AudioSettingsView()
            .environment(AppState())
            .environment(AudioDeviceManager())
            .frame(width: 760, height: 720)
            .background(DS.Palette.window)
        let bitmap = try #require(RetinaHost.render(page, appearance: NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(!png.isEmpty)
        if let directory = Self.outputDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("audio-\(appearance).png"))
        }
    }
}
