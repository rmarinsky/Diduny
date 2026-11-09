import AppKit
@testable import Diduny
import SwiftUI
import Testing

/// At the 1000 pt minimum window no Settings page is wider than its column, and no page moves the sidebar.
@MainActor
@Suite("Settings pages fit the window", .serialized)
struct SettingsPageWidthTests {
    /// 1000 - 238 sidebar - 0.5 rule.
    static let pageWidth: CGFloat = 761.5
    /// Less the 24 pt page padding on each side; `Form` pages use the full page width.
    static let column: CGFloat = 713.5

    private final class Box { var width: CGFloat = 0 }

    private func settle() async {
        for _ in 0 ..< 15 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
    }

    private func contentWidth(_ page: some View) async -> CGFloat {
        let box = Box()
        let appState = AppState()
        let host = NSHostingView(rootView: page
            .environment(appState)
            .environment(AudioDeviceManager())
            .environment(\.pageContentWidthProbe) { box.width = $0 }
            .frame(width: Self.pageWidth, height: 680))
        host.frame = NSRect(x: 0, y: 0, width: Self.pageWidth, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        await settle()
        window.contentView = nil
        return box.width
    }

    private func expectFits(_ page: some View, limit: CGFloat = column, _ name: String) async {
        let width = await contentWidth(page)
        #expect(width > 0, "\(name) reported no width")
        #expect(width <= limit + 0.5, "\(name) is \(width) wide, the column is \(limit)")
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

    @Test func aWidePageKeepsTheSidebarAtTheWindowEdge() async throws {
        final class Probe { var sidebarX: CGFloat? }
        let probe = Probe()
        let host = NSHostingView(rootView: MainWindowColumns {
            Color.clear.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minX }) { probe.sidebarX = $0 }
        } detail: {
            Color.clear.frame(width: 2000)
        }.frame(width: 1000, height: 680))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        await settle()
        #expect(try #require(probe.sidebarX) == 0)
        window.contentView = nil
    }
}
