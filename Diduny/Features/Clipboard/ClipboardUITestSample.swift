#if TEST_BUILD
    import AppKit

    /// `--ui-testing-clipboard=sample` or `=empty`: a fixed history in a temporary folder, for the Clipboard page.
    @MainActor
    enum ClipboardUITestSample {
        static func makeStore(empty: Bool) -> ClipboardHistoryStore {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DidunyClipboardSample-\(UUID().uuidString)")
            let store = ClipboardHistoryStore(directory: directory)
            if empty { return store }
            let now = Date()
            func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
            func app(_ name: String) -> ClipboardSourceApp { ClipboardSourceApp(name: name, bundleID: "sample.\(name)") }

            store.addCopiedText("bun run test --filter short-links", app: app("Ghostty"), date: at(60 * 26))
            store.addDidunyText(
                "Thanks, I will send the proposal by Friday.", origin: .translated, app: app("Slack"), date: at(60 * 25)
            )
            store.addImage(picture(width: 820, height: 460), app: .unknown, date: at(60 * 24.5))
            store.addCopiedText("https://example.com/pull/26", app: app("Safari"), date: at(47))
            store.addDidunyText(
                "Standup notes for the release: the short link fix is merged, the event page goes out on Thursday.",
                origin: .dictated, app: app("Telegram"), date: at(11)
            )
            store.addImage(picture(width: 1440, height: 900), app: app("Safari"), date: at(4))
            store.addCopiedText("ssh deploy@example.com", app: app("Ghostty"), date: at(1))
            return store
        }

        private static func picture(width: Int, height: Int) -> Data {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            NSColor.systemTeal.setFill()
            NSRect(x: width / 2, y: height * 3 / 4, width: width * 2 / 5, height: height / 10).fill()
            NSColor.separatorColor.setFill()
            NSRect(x: width / 12, y: height / 6, width: width / 3, height: height * 2 / 3).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:]) ?? Data()
        }
    }
#endif
