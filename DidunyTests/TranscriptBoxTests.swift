import AppKit
@testable import Diduny
import SwiftUI
import Testing

/// Live text starts at the top and scrolls only once the box is full (Roman, 2026-11-09).
@MainActor
@Suite("Transcript box growth")
struct TranscriptBoxTests {
    @Observable @MainActor final class Probe {
        var lines = 1
        var firstLineY: CGFloat?
    }

    private struct Sample: View {
        let probe: Probe

        var body: some View {
            TranscriptBox(height: 120) {
                ForEach(0 ..< probe.lines, id: \.self) { index in
                    Color.clear.frame(height: 20).background(GeometryReader { geometry in
                        Color.clear.onAppear {
                            if index == 0 { probe.firstLineY = geometry.frame(in: .global).minY }
                        }
                    })
                }
            }
        }
    }

    private func settle() async {
        for _ in 0 ..< 10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    @Test func shortTextIsAtTheTopAndLongTextScrollsToTheNewestLine() async throws {
        let probe = Probe()
        let host = NSHostingView(rootView: Sample(probe: probe))
        host.frame = NSRect(x: 0, y: 0, width: 274, height: 120)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        await settle()
        let firstLineY = try #require(probe.firstLineY)
        #expect(abs(firstLineY - DS.Size.boxPadding) < 1)

        let scroll = try #require(scrollView(in: host))
        #expect(scroll.documentVisibleRect.minY < 1)

        probe.lines = 30
        await settle()
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > 120)
        #expect(abs(scroll.documentVisibleRect.maxY - document.frame.height) < 1)
    }
}
