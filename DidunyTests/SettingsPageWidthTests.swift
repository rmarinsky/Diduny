import AppKit
@testable import Diduny
import SwiftUI
import Testing

/// At the 1000 pt minimum window and in wider ones no Settings page is wider than its column, and no page
/// moves the sidebar.
@MainActor
@Suite("Settings pages fit the window", .serialized)
struct SettingsPageWidthTests {
    /// 1000 - 238 sidebar - 0.5 rule.
    static let pageWidth: CGFloat = 761.5
    /// Less the 24 pt page padding on each side; `Form` pages use the full page width.
    static let column: CGFloat = 713.5
    static let windowWidths: [CGFloat] = [1000, 1280, 1600]

    static func pageWidth(window: CGFloat) -> CGFloat { window - 238.5 }
    /// The column a scrolling page gets: the page less its padding, up to the page's reading width.
    static func column(window: CGFloat, max: CGFloat = DS.Layout.columnMaxWidth) -> CGFloat {
        min(pageWidth(window: window) - 48, max)
    }

    private final class Box { var width: CGFloat = 0 }

    private func settle() async {
        for _ in 0 ..< 15 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
    }

    private func contentWidth(_ page: some View, language: String, pageWidth: CGFloat) async -> CGFloat {
        let box = Box()
        let appState = AppState()
        let host = NSHostingView(rootView: page
            .environment(appState)
            .environment(AudioDeviceManager())
            .environment(\.locale, Locale(identifier: language))
            .environment(\.pageContentWidthProbe) { box.width = $0 }
            .frame(width: pageWidth, height: 680))
        host.frame = NSRect(x: 0, y: 0, width: pageWidth, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        await settle()
        window.contentView = nil
        return box.width
    }

    private func expectFits(_ page: some View, limit: CGFloat = column, _ name: String) async {
        for language in ["en", "uk"] {
            let width = await contentWidth(page, language: language, pageWidth: Self.pageWidth)
            #expect(width > 0, "\(name) [\(language)] reported no width")
            #expect(width <= limit + 0.5, "\(name) [\(language)] is \(width) wide, the column is \(limit)")
        }
    }

    /// In every window width the page stays within its column (up to its reading width); table pages fill it.
    private func expectGrows(
        _ page: some View, max: CGFloat = DS.Layout.columnMaxWidth, fills: Bool = false, _ name: String
    ) async {
        for window in Self.windowWidths {
            let limit = Self.column(window: window, max: max)
            let width = await contentWidth(page, language: "en", pageWidth: Self.pageWidth(window: window))
            #expect(width <= limit + 0.5, "\(name) at \(window) is \(width) wide, the column is \(limit)")
            if fills { #expect(width >= limit - 0.5, "\(name) at \(window) is \(width), not filling \(limit)") }
        }
    }

    @Test func wideProviders() async {
        await expectGrows(ProvidersSettingsView(hasKey: true), max: DS.Layout.wideColumnMaxWidth, fills: true, "Providers")
    }

    @Test func wideLocalModels() async {
        await expectGrows(OfflineModelsSettingsView(), max: DS.Layout.wideColumnMaxWidth, fills: true, "Local models")
    }

    @Test func wideModes() async { await expectGrows(ModesSettingsView(), "Modes") }
    @Test func wideGeneral() async { await expectGrows(GeneralSettingsView(), "General") }
    @Test func wideLanguages() async { await expectGrows(LanguagesSettingsView(), "Languages") }
    @Test func wideAudio() async { await expectGrows(AudioSettingsView(), "Audio") }
    @Test func wideShortcuts() async { await expectGrows(ShortcutsSettingsView(), "Shortcuts") }
    @Test func wideAbout() async { await expectGrows(AboutSettingsView(), "About") }

    @Test func clampFitsTheWindowOnTheScreen() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let frame = MainWindowController.clamp(NSRect(x: 900, y: 0, width: 1600, height: 1000), to: visible)
        #expect(frame == visible)
        let moved = MainWindowController.clamp(NSRect(x: 900, y: 100, width: 1000, height: 680), to: visible)
        #expect(moved == NSRect(x: 440, y: 100, width: 1000, height: 680))
    }

    @Test func providersWithoutAKey() async { await expectFits(ProvidersSettingsView(hasKey: false), "Providers") }
    @Test func providersWithAKey() async { await expectFits(ProvidersSettingsView(hasKey: true), "Providers + key") }
    @Test func modes() async { await expectFits(ModesSettingsView(), "Modes") }
    @Test func localModels() async { await expectFits(OfflineModelsSettingsView(), "Local models") }
    @Test func general() async { await expectFits(GeneralSettingsView(), "General") }
    @Test func languages() async { await expectFits(LanguagesSettingsView(), "Languages") }
    @Test func audio() async { await expectFits(AudioSettingsView(), "Audio") }
    @Test func meetings() async { await expectFits(MeetingSettingsView(), limit: Self.pageWidth, "Calendar & meetings") }
    @Test func shortcuts() async { await expectFits(ShortcutsSettingsView(), "Shortcuts") }
    @Test func account() async { await expectFits(AccountSettingsView(), limit: Self.pageWidth, "Account") }
    @Test func about() async { await expectFits(AboutSettingsView(), "About") }

    @Test(arguments: windowWidths)
    func aWidePageKeepsTheSidebarAtTheWindowEdge(window: CGFloat) async throws {
        final class Probe { var sidebarX: CGFloat? }
        let probe = Probe()
        let host = NSHostingView(rootView: MainWindowColumns {
            Color.clear.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minX }) { probe.sidebarX = $0 }
        } detail: {
            Color.clear.frame(width: 2000)
        }.frame(width: window, height: 680))
        host.frame = NSRect(x: 0, y: 0, width: window, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        await settle()
        #expect(try #require(probe.sidebarX) == 0)
        window.contentView = nil
    }
}
