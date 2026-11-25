import AppKit
@testable import Diduny
import Foundation
import Testing

@MainActor
private final class FakePasteboard: ClipboardPasteboard {
    var changeCount = 0
    var types: [String] = []
    private var text: String?
    private var image: Data?
    private var files: [URL] = []

    func fileURLs() -> [URL] { files }
    func write(fileURLs: [URL]) { put(files: fileURLs, types: ["public.file-url"]) }
    func string() -> String? { text }
    func imageData() -> Data? { image }

    func write(text: String) { put(text: text, image: nil, types: ["public.utf8-plain-text"]) }
    func write(png: Data) { put(text: nil, image: png, types: ["public.png"]) }

    /// A copy made in another app.
    func put(text: String? = nil, image: Data? = nil, files: [URL] = [], types: [String]) {
        self.text = text
        self.image = image
        self.files = files
        self.types = types
        changeCount += 1
    }

    var currentText: String? { text }
    var currentImage: Data? { image }
    var currentFiles: [URL] { files }
}

private func png(width: Int = 40, height: Int = 20, shade: CGFloat = 0.5) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: shade, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// The clipboard history: the store on disk, the watcher's rules, Diduny's own entries and the page model.
@MainActor
final class ClipboardHistoryTests {
    private let box = IsolatedSettings("ClipboardHistoryTests")
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipboardHistoryTests-\(UUID().uuidString)")
    private let pasteboard = FakePasteboard()
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var frontmost = ClipboardSourceApp(name: "Ghostty", bundleID: "com.mitchellh.ghostty")
    private lazy var store = ClipboardHistoryStore(directory: directory)
    private lazy var service = makeService(store: store)

    private var imagesURL: URL { directory.appendingPathComponent("Images") }

    /// The service exists before the first copy, as in the app.
    init() {
        _ = service
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeService(store: ClipboardHistoryStore, isActive: Bool = true) -> ClipboardHistoryService {
        ClipboardHistoryService(
            store: store, pasteboard: pasteboard, settings: box.settings,
            frontmostApp: { [unowned self] in frontmost }, now: { [unowned self] in now }, isActive: isActive
        )
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: imagesURL.path)) ?? []).sorted()
    }

    private func copyText(_ text: String) {
        pasteboard.put(text: text, types: ["public.utf8-plain-text"])
        service.poll()
    }

    // MARK: - Store

    @Test("a text and an image survive a reload; the image is a file, not part of the index")
    func roundTrip() throws {
        store.addCopiedText("ssh deploy@example.com", app: frontmost, date: now)
        let image = try #require(store.addImage(png(width: 600, height: 300), app: .unknown, date: now.addingTimeInterval(1)))
        store.addDidunyText("Standup notes", origin: .dictated, app: frontmost, date: now.addingTimeInterval(2))

        #expect(image.pixelWidth == 600)
        #expect(image.pixelHeight == 300)
        let imageFile = try #require(image.imageFile)
        let thumbnailFile = try #require(image.thumbnailFile)
        #expect(files() == [imageFile, thumbnailFile].sorted())
        #expect(store.imageData(for: image) != nil)
        let thumbnailURL = try #require(store.thumbnailURL(for: image))
        let thumbnail = try #require(NSBitmapImageRep(data: Data(contentsOf: thumbnailURL)))
        #expect(max(thumbnail.pixelsWide, thumbnail.pixelsHigh) == ClipboardHistoryStore.thumbnailPixelSize)

        let index = try Data(contentsOf: directory.appendingPathComponent("index.jsonl"))
        #expect(index.split(separator: 0x0A).count == 3)
        #expect(index.count < 2000)

        let reloaded = ClipboardHistoryStore(directory: directory)
        #expect(reloaded.entries == store.entries)
        #expect(reloaded.entries.map(\.kind) == [.diduny, .image, .text])
        #expect(reloaded.entries.last?.text == "ssh deploy@example.com")
        #expect(reloaded.entries.last?.appName == "Ghostty")
        #expect(reloaded.entries.last?.bundleID == "com.mitchellh.ghostty")
        #expect(reloaded.entries.first?.origin == .dictated)
    }

    @Test("TIFF data is kept as one PNG file")
    func tiffBecomesPNG() throws {
        let tiff = try #require(NSBitmapImageRep(data: png())?.tiffRepresentation)
        let entry = try #require(store.addImage(tiff, app: frontmost, date: now))
        let data = try #require(store.imageData(for: entry))
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(entry.imageBytes == data.count)
    }

    @Test("data that is not an image adds nothing")
    func notAnImage() {
        #expect(store.addImage(Data("not an image".utf8), app: frontmost, date: now) == nil)
        #expect(store.entries.isEmpty)
        #expect(files().isEmpty)
    }

    @Test("deleting an entry deletes its files and its index line")
    func deleteRemovesFiles() throws {
        let image = try #require(store.addImage(png(), app: frontmost, date: now))
        store.addCopiedText("kept", app: frontmost, date: now)
        #expect(files().count == 2)

        store.delete(id: image.id)

        #expect(files().isEmpty)
        #expect(ClipboardHistoryStore(directory: directory).entries.map(\.text) == ["kept"])
    }

    @Test("clear deletes every entry and the folder")
    func clearRemovesFolder() {
        store.addCopiedText("one", app: frontmost, date: now)
        store.addImage(png(), app: frontmost, date: now)

        store.clear()

        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(ClipboardHistoryStore(directory: directory).entries.isEmpty)
    }

    @Test("a text longer than the cap is cut to the cap")
    func textCap() {
        let entry = store.addCopiedText(String(repeating: "a", count: ClipboardHistoryStore.textCharacterCap + 10), app: frontmost, date: now)
        #expect(entry?.text?.count == ClipboardHistoryStore.textCharacterCap)
    }

    @Test("a line of the index that does not decode is skipped")
    func badIndexLine() throws {
        store.addCopiedText("one", app: frontmost, date: now)
        let url = directory.appendingPathComponent("index.jsonl")
        try (Data(contentsOf: url) + Data("{broken\n".utf8)).write(to: url)
        store.addCopiedText("two", app: frontmost, date: now)
        #expect(ClipboardHistoryStore(directory: directory).entries.map(\.text) == ["two", "one"])
    }

    // MARK: - Pruning

    @Test("each retention removes what is older and keeps the rest", arguments: ClipboardRetention.allCases)
    func pruneByRetention(retention: ClipboardRetention) throws {
        // Ages in seconds, oldest first: 30 min, 2 h, 36 h, 3 days, 10 days, 40 days.
        let ages: [TimeInterval] = [40 * 86400, 10 * 86400, 3 * 86400, 36 * 3600, 2 * 3600, 1800]
        for age in ages {
            store.addCopiedText("age \(Int(age))", app: frontmost, date: now.addingTimeInterval(-age))
        }
        let old = try #require(store.addImage(png(), app: frontmost, date: now.addingTimeInterval(-41 * 86400 + 1)))
        _ = old

        store.prune(retention: retention, now: now)

        let expectedTexts = ages.filter { age in retention.interval.map { age <= $0 } ?? true }
        #expect(store.entries.filter { $0.kind == .text }.count == expectedTexts.count)
        let keepsAll = retention == .forever || retention == .never
        #expect(store.entries.contains { $0.kind == .image } == keepsAll)
        #expect(files().isEmpty == !keepsAll)
        #expect(ClipboardHistoryStore(directory: directory).entries == store.entries)
    }

    @Test("over the size cap the oldest images go first and texts stay")
    func pruneBySizeCap() throws {
        let probe = try #require(store.addImage(png(shade: 0.1), app: frontmost, date: now))
        let size = try #require(probe.imageBytes)
        store.clear()

        let capped = ClipboardHistoryStore(directory: directory, imageBytesCap: size * 2 + size / 2)
        capped.addCopiedText("old text", app: frontmost, date: now)
        let first = try #require(capped.addImage(png(shade: 0.1), app: frontmost, date: now.addingTimeInterval(1)))
        let second = try #require(capped.addImage(png(shade: 0.2), app: frontmost, date: now.addingTimeInterval(2)))
        let third = try #require(capped.addImage(png(shade: 0.3), app: frontmost, date: now.addingTimeInterval(3)))

        capped.prune(retention: .forever, now: now.addingTimeInterval(4))

        #expect(capped.entries.map(\.id) == [third.id, second.id, capped.entries.last!.id])
        #expect(capped.entries.last?.text == "old text")
        #expect(!files().contains(first.imageFile!))
        #expect(files().count == 4)
    }

    @Test("the service prunes after a capture and when asked")
    func servicePrunes() {
        box.settings.clipboardRetention = .oneHour
        copyText("first")
        now = now.addingTimeInterval(3601)
        copyText("second")
        #expect(store.entries.map(\.text) == ["second"])

        now = now.addingTimeInterval(3601)
        service.prune()
        #expect(store.entries.isEmpty)
    }

    // MARK: - Capture rules

    @Test("a copy is recorded with the frontmost app, one entry per copy")
    func capture() {
        copyText("one")
        frontmost = ClipboardSourceApp(name: "Safari", bundleID: "com.apple.Safari")
        copyText("two")
        service.poll()

        #expect(store.entries.map(\.text) == ["two", "one"])
        #expect(store.entries.map(\.appName) == ["Safari", "Ghostty"])
        #expect(store.entries.map(\.bundleID) == ["com.apple.Safari", "com.mitchellh.ghostty"])
        #expect(store.entries.allSatisfy { $0.kind == .text })
    }

    @Test("what is on the pasteboard at the start is not recorded")
    func nothingAtStart() {
        pasteboard.put(text: "before launch", types: ["public.utf8-plain-text"])
        let started = makeService(store: store)
        started.poll()
        #expect(store.entries.isEmpty)
    }

    @Test("the same copy twice in a row is one entry; after another copy it is recorded again")
    func deduplication() {
        copyText("same")
        copyText("same")
        #expect(store.entries.count == 1)

        copyText("other")
        copyText("same")
        #expect(store.entries.map(\.text) == ["same", "other", "same"])

        pasteboard.put(image: png(), types: ["public.png"])
        service.poll()
        pasteboard.put(image: png(), types: ["public.png"])
        service.poll()
        #expect(store.entries.filter { $0.kind == .image }.count == 1)
        #expect(files().count == 2)
    }

    @Test("concealed, transient and generated copies are skipped", arguments: Array(ClipboardHistoryService.skippedTypes).sorted())
    func markedTypesSkipped(type: String) {
        pasteboard.put(text: "hunter2", types: ["public.utf8-plain-text", type])
        service.poll()
        #expect(store.entries.isEmpty)
        // The setting is about apps; the marker types are skipped whatever it says.
        box.settings.clipboardSkipPasswordManagers = false
        pasteboard.put(text: "hunter3", types: ["public.utf8-plain-text", type])
        service.poll()
        #expect(store.entries.isEmpty)
    }

    @Test("the marker types are the nspasteboard.org ones and 1Password's")
    func markerTypes() {
        #expect(ClipboardHistoryService.skippedTypes == [
            "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
            "com.agilebits.onepassword",
        ])
    }

    @Test("nothing copied while a password manager is frontmost is kept, unless the setting is off")
    func passwordManagerSkipped() {
        frontmost = ClipboardSourceApp(name: "1Password", bundleID: "com.1password.1password")
        copyText("hunter2")
        #expect(store.entries.isEmpty)

        frontmost = ClipboardSourceApp(name: "Keychain Access", bundleID: "com.apple.keychainaccess")
        copyText("hunter3")
        #expect(store.entries.isEmpty)

        box.settings.clipboardSkipPasswordManagers = false
        copyText("hunter4")
        #expect(store.entries.map(\.text) == ["hunter4"])
    }

    @Test("an image is recorded unless Keep screenshots is off")
    func screenshots() {
        pasteboard.put(image: png(width: 64, height: 32), types: ["public.png", "public.tiff"])
        service.poll()
        #expect(store.entries.first?.kind == .image)
        #expect(store.entries.first?.pixelWidth == 64)

        box.settings.clipboardKeepScreenshots = false
        pasteboard.put(image: png(shade: 0.9), types: ["public.png"])
        service.poll()
        #expect(store.entries.count == 1)
    }

    @Test("blank text and empty copies add nothing")
    func notKept() {
        pasteboard.put(text: "  \n", types: ["public.utf8-plain-text"])
        service.poll()
        pasteboard.put(types: [])
        service.poll()
        #expect(store.entries.isEmpty)
    }

    @Test("a file copy is one files entry with paths only, whatever text it carries")
    func filesCaptured() throws {
        let urls = [URL(fileURLWithPath: "/tmp/report.pdf"), URL(fileURLWithPath: "/tmp/chart.png")]
        pasteboard.put(text: "report.pdf", files: urls, types: ["public.file-url", "public.utf8-plain-text"])
        service.poll()
        let entry = try #require(store.entries.first)
        #expect(store.entries.count == 1)
        #expect(entry.kind == .files)
        #expect(entry.filePaths == ["/tmp/report.pdf", "/tmp/chart.png"])
        #expect(entry.fileNames == ["report.pdf", "chart.png"])
        #expect(entry.text == nil)
        #expect(entry.appName == "Ghostty")

        // The same files again in a row are one entry; it survives a reload.
        pasteboard.put(files: urls, types: ["public.file-url"])
        service.poll()
        #expect(store.entries.count == 1)
        #expect(ClipboardHistoryStore(directory: directory).entries == store.entries)
    }

    @Test("a file copy with no readable file URL, or from a password manager, adds nothing")
    func filesSkipped() {
        pasteboard.put(files: [], types: ["public.file-url"])
        service.poll()
        frontmost = ClipboardSourceApp(name: "1Password", bundleID: "com.1password.1password")
        pasteboard.put(files: [URL(fileURLWithPath: "/tmp/a.txt")], types: ["public.file-url"])
        service.poll()
        #expect(store.entries.isEmpty)
    }

    @Test("restoring files puts their URLs back, adds no entry, and skips files that are gone")
    func filesRestored() throws {
        let kept = directory.appendingPathComponent("kept.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: kept)
        let gone = directory.appendingPathComponent("gone.txt")
        pasteboard.put(files: [kept, gone], types: ["public.file-url"])
        service.poll()
        let entry = try #require(store.entries.first)

        pasteboard.put(text: "something else", types: ["public.utf8-plain-text"])
        service.poll()
        let before = store.entries
        #expect(service.copyToPasteboard(entry))
        service.poll()
        #expect(pasteboard.currentFiles == [kept])
        #expect(store.entries == before)

        try FileManager.default.removeItem(at: kept)
        #expect(!service.copyToPasteboard(entry))
    }

    @Test("a service that was not started records nothing")
    func inactive() {
        let idle = makeService(store: store, isActive: false)
        pasteboard.put(text: "one", types: ["public.utf8-plain-text"])
        idle.poll()
        idle.recordDelivery("dictated", origin: .dictated, pasted: true)
        #expect(store.entries.isEmpty)
    }

    @Test("with Never nothing new is recorded, what is kept stays, and another value resumes capture")
    func never() {
        copyText("kept before")
        store.addCopiedText("very old", app: frontmost, date: now.addingTimeInterval(-400 * 86400))
        let page = model()

        page.setRetention(.never)
        now = now.addingTimeInterval(90 * 86400)
        copyText("while off")
        pasteboard.put(image: png(), types: ["public.png"])
        service.poll()
        service.withoutCapture { pasteboard.write(text: "dictated while off") }
        service.recordDelivery("dictated while off", origin: .dictated, pasted: true)
        service.prune()
        service.poll()
        #expect(store.entries.map(\.text) == ["very old", "kept before"])
        #expect(ClipboardHistoryStore(directory: directory).entries.count == 2)

        // Back on: what is on the pasteboard at that moment is not recorded.
        pasteboard.put(text: "copied just before", types: ["public.utf8-plain-text"])
        page.setRetention(.forever)
        service.poll()
        #expect(store.entries.count == 2)
        copyText("after")
        service.recordDelivery("dictated after", origin: .dictated, pasted: true)
        #expect(store.entries.map(\.text) == ["dictated after", "after", "very old", "kept before"])
    }

    // MARK: - Entries from Diduny

    @Test("a delivery is exactly one Diduny entry and the watcher adds none")
    func deliveryIsOneEntry() {
        frontmost = ClipboardSourceApp(name: "Telegram", bundleID: "ru.keepcoder.Telegram")
        service.withoutCapture { pasteboard.write(text: "Standup notes") }
        service.poll()
        service.recordDelivery("Standup notes", origin: .dictated, pasted: true)
        service.poll()

        #expect(store.entries.count == 1)
        #expect(store.entries.first?.kind == .diduny)
        #expect(store.entries.first?.origin == .dictated)
        #expect(ClipboardPageModel.caption(for: store.entries[0]) == "Dictated into Telegram")

        // The same text copied by hand later is its own row.
        copyText("Standup notes")
        #expect(store.entries.map(\.kind) == [.text, .diduny])
    }

    @Test("a tick during the suspension records nothing, and nested suspensions are counted")
    func suspension() {
        service.suspend()
        service.suspend()
        pasteboard.write(text: "selection")
        service.poll()
        service.resume()
        pasteboard.write(text: "translation")
        service.poll()
        pasteboard.write(text: "restored clipboard")
        service.resume()
        service.poll()
        #expect(store.entries.isEmpty)

        copyText("a real copy")
        #expect(store.entries.map(\.text) == ["a real copy"])
    }

    @Test("a translation reads Translated into the app; a copy with no paste names no app")
    func deliveryCaptions() {
        frontmost = ClipboardSourceApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        service.recordDelivery("Thanks", origin: .translated, pasted: true)
        service.recordDelivery("Thanks", origin: .translated, pasted: false)
        service.recordDelivery("Hello", origin: .dictated, pasted: false)

        #expect(store.entries.map(ClipboardPageModel.caption) == ["Dictated", "Translated", "Translated into Slack"])
        #expect(store.entries.map(\.appName) == [nil, nil, "Slack"])
    }

    @Test("with Keep what Diduny pastes off a delivery adds no row of any kind")
    func deliveryOff() {
        box.settings.clipboardKeepDidunyPastes = false
        service.withoutCapture { pasteboard.write(text: "Standup notes") }
        service.recordDelivery("Standup notes", origin: .dictated, pasted: true)
        service.poll()
        #expect(store.entries.isEmpty)
    }

    // MARK: - Page model

    private func model() -> ClipboardPageModel {
        ClipboardPageModel(service: service, settings: box.settings, calendar: calendar, now: { [unowned self] in now })
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2027-01-15 08:00 UTC is `now`; entries today, yesterday and four days back.
    private func seedPage() {
        store.addCopiedText("bun run test", app: ClipboardSourceApp(name: "Ghostty", bundleID: "g"), date: now.addingTimeInterval(-4 * 86400))
        store.addDidunyText("Thanks, see you Friday", origin: .translated, app: ClipboardSourceApp(name: "Slack", bundleID: "s"), date: now.addingTimeInterval(-86400))
        store.addImage(png(width: 82, height: 46), app: .unknown, date: now.addingTimeInterval(-86400 + 60))
        store.addCopiedText("https://example.com/pull/26", app: ClipboardSourceApp(name: "Safari", bundleID: "sf"), date: now.addingTimeInterval(-3600))
        store.addDidunyText("Standup notes\nfor the release", origin: .dictated, app: ClipboardSourceApp(name: "Telegram", bundleID: "t"), date: now.addingTimeInterval(-600))
        store.addCopiedText("ssh deploy@example.com", app: ClipboardSourceApp(name: "Ghostty", bundleID: "g"), date: now.addingTimeInterval(-60))
    }

    @Test("entries are grouped by day, newest first, under Today, Yesterday and the date")
    func dayGrouping() {
        now = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86400) + 8 * 3600)
        seedPage()
        let page = model()
        let days = page.days

        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        let older = calendar.startOfDay(for: now.addingTimeInterval(-4 * 86400))
        #expect(days.map(\.title) == ["Today", "Yesterday", older.formatted(style)])
        #expect(days.map(\.entries.count) == [3, 2, 1])
        #expect(days[0].entries.map(\.text) == ["ssh deploy@example.com", "Standup notes\nfor the release", "https://example.com/pull/26"])
        #expect(days[1].entries.map(\.kind) == [.image, .diduny])
        #expect(!page.isEmpty)
    }

    @Test("titles and captions of each kind")
    func rowText() {
        seedPage()
        let entries = store.entries
        #expect(entries.map(ClipboardPageModel.title) == [
            "ssh deploy@example.com", "Standup notes for the release", "https://example.com/pull/26",
            "Screenshot, 82 × 46", "Thanks, see you Friday", "bun run test",
        ])
        #expect(entries.map(ClipboardPageModel.caption) == [
            "Copied in Ghostty", "Dictated into Telegram", "Copied in Safari", "Screenshot", "Translated into Slack",
            "Copied in Ghostty",
        ])
        let copiedImage = ClipboardEntry(
            id: UUID(), date: now, kind: .image, appName: "Safari", pixelWidth: 1440, pixelHeight: 900, signature: ""
        )
        #expect(ClipboardPageModel.title(for: copiedImage) == "Image, 1440 × 900")
        #expect(ClipboardPageModel.caption(for: copiedImage) == "Copied in Safari")
    }

    @Test("each filter shows its kind only, and a day with nothing to show is left out")
    func filters() {
        now = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86400) + 8 * 3600)
        seedPage()
        let page = model()

        page.filter = .text
        #expect(page.days.flatMap(\.entries).allSatisfy { $0.kind == .text })
        #expect(page.days.map(\.entries.count) == [2, 1])
        #expect(page.days.map(\.title).contains("Yesterday") == false)

        page.filter = .screenshots
        #expect(page.days.map(\.title) == ["Yesterday"])
        #expect(page.days.flatMap(\.entries).map(\.kind) == [.image])

        page.filter = .fromDiduny
        #expect(page.days.flatMap(\.entries).map(\.origin) == [.dictated, .translated])

        page.filter = .all
        #expect(page.days.flatMap(\.entries).count == 6)
    }

    @Test("search covers the full text and the app name, and combines with the filter")
    func search() {
        store.addCopiedText(String(repeating: "x", count: 5000) + " needle at the end", app: frontmost, date: now)
        seedPage()
        let page = model()

        page.query = "  GHOSTTY "
        #expect(page.days.flatMap(\.entries).count == 3)

        page.query = "needle at"
        #expect(page.days.flatMap(\.entries).count == 1)

        page.query = "telegram"
        #expect(page.days.flatMap(\.entries).map(\.kind) == [.diduny])
        page.filter = .text
        #expect(page.days.isEmpty)
        #expect(!page.isEmpty)

        page.filter = .all
        page.query = "screenshot"
        #expect(page.days.flatMap(\.entries).map(\.kind) == [.image])

        page.query = "nothing like this"
        #expect(page.days.isEmpty)
    }

    @Test("Copy puts the full entry back, adds no entry, moves nothing and reads Copied")
    func copyFromPage() throws {
        seedPage()
        let page = model()
        let before = store.entries
        let text = try #require(before.first { $0.kind == .diduny })
        let image = try #require(before.first { $0.kind == .image })

        page.copy(text)
        service.poll()
        #expect(pasteboard.currentText == text.text)
        #expect(page.copiedID == text.id)
        #expect(store.entries == before)

        page.copy(image)
        service.poll()
        #expect(pasteboard.currentImage == store.imageData(for: image))
        #expect(page.copiedID == image.id)
        #expect(store.entries == before)
        #expect(ClipboardHistoryStore(directory: directory).entries == before)
    }

    @Test("delete removes one row; Clear asks first and Clear everything empties the page")
    func deleteAndClear() throws {
        seedPage()
        let page = model()
        page.delete(try #require(store.entries.first))
        #expect(store.entries.count == 5)

        page.isAskingToClear = true
        #expect(store.entries.count == 5)
        page.clearEverything()
        #expect(page.isEmpty)
        #expect(!page.isAskingToClear)
        #expect(files().isEmpty)
    }

    @Test("a shorter Keep the clipboard for removes older rows at once")
    func retentionSetting() {
        seedPage()
        let page = model()
        #expect(page.retention == .oneWeek)

        page.setRetention(.oneDay)
        #expect(box.settings.clipboardRetention == .oneDay)
        #expect(store.entries.count == 5)

        page.setRetention(.oneHour)
        #expect(store.entries.count == 3)
    }

    // MARK: - Settings

    @Test("the menu list shows ten rows unless the setting says otherwise")
    func menuVisibleRowsDefault() {
        #expect(box.settings.clipboardMenuVisibleRows == 10)
        box.settings.clipboardMenuVisibleRows = 15
        #expect(box.settings.clipboardMenuVisibleRows == 15)
    }

    @Test("defaults: one week, and the three switches on")
    func settingsDefaults() {
        let settings = box.settings
        #expect(settings.clipboardRetention == .oneWeek)
        #expect(settings.clipboardKeepScreenshots)
        #expect(settings.clipboardKeepDidunyPastes)
        #expect(settings.clipboardSkipPasswordManagers)
        #expect(ClipboardRetention.allCases.map(\.displayName) == ["Never", "1 hour", "1 day", "2 days", "1 week", "1 month", "Forever"])
    }

    @Test("every key starts with clipboard. and the page writes nothing else")
    func settingsKeys() {
        let before = Set(box.defaults.dictionaryRepresentation().keys)
        let page = model()
        page.setRetention(.forever)
        page.setKeepScreenshots(false)
        page.setKeepDidunyPastes(false)
        page.setSkipPasswordManagers(false)
        page.setMenuVisibleRows(5)

        let written = Set(box.defaults.dictionaryRepresentation().keys).subtracting(before)
        #expect(written == Set(SettingsStorage.ClipboardKey.allCases.map(\.rawValue)))
        #expect(written.allSatisfy { $0.hasPrefix("clipboard.") })
        #expect(box.settings.clipboardRetention == .forever)
        #expect(!box.settings.clipboardKeepScreenshots)
        #expect(!box.settings.clipboardKeepDidunyPastes)
        #expect(!box.settings.clipboardSkipPasswordManagers)
        #expect(box.settings.clipboardMenuVisibleRows == 5)
    }

    // MARK: - Menu bar list

    private func entry(
        _ kind: ClipboardEntry.Kind, text: String? = nil, paths: [String]? = nil, app: String? = "Ghostty", date: Date? = nil
    ) -> ClipboardEntry {
        ClipboardEntry(id: UUID(), date: date ?? now, kind: kind, appName: app, text: text, filePaths: paths, signature: "")
    }

    @Test("a menu row is the first line, whitespace collapsed, cut at 50 characters")
    func menuRowTitle() {
        #expect(ClipboardMenuRow.title(for: entry(.text, text: "  \n\n  hello \t  big\n world\nsecond line")) == "hello big")
        #expect(ClipboardMenuRow.title(for: entry(.text, text: "short")) == "short")

        let exact = String(repeating: "a", count: 50)
        #expect(ClipboardMenuRow.title(for: entry(.text, text: exact)) == exact)
        let cut = ClipboardMenuRow.title(for: entry(.text, text: exact + "b"))
        #expect(cut == String(repeating: "a", count: 49) + "…")
        #expect(cut.count == 50)
    }

    @Test("a menu row names an image by its size and files by their names")
    func menuRowTitleOtherKinds() {
        var image = entry(.image)
        image.pixelWidth = 1440
        image.pixelHeight = 900
        #expect(ClipboardMenuRow.title(for: image) == "Image, 1440 × 900")
        image.appName = nil
        #expect(ClipboardMenuRow.title(for: image) == "Screenshot, 1440 × 900")

        #expect(ClipboardMenuRow.title(for: entry(.files, paths: ["/a/report.pdf"])) == "report.pdf")
        #expect(ClipboardMenuRow.title(for: entry(.files, paths: ["/a/a.pdf", "/b/b.png", "/c/c.txt"])) == "3 files: a.pdf, b.png, c.txt")
        let many = (1 ... 12).map { "/x/document-\($0).pdf" }
        let title = ClipboardMenuRow.title(for: entry(.files, paths: many))
        #expect(title.count == 50)
        #expect(title.hasPrefix("12 files: document-1.pdf") && title.hasSuffix("…"))
    }

    @Test("the second line is the source and the time; an earlier day adds the date")
    func menuRowSubtitle() {
        let calendar = Calendar(identifier: .gregorian)
        let today = ClipboardMenuRow(entry(.text, text: "x"), now: now, calendar: calendar)
        #expect(today.subtitle == "Copied in Ghostty · " + now.formatted(date: .omitted, time: .shortened))

        let old = ClipboardMenuRow(entry(.text, text: "x", date: now.addingTimeInterval(-3 * 86400)), now: now, calendar: calendar)
        #expect(old.subtitle.hasPrefix("Copied in Ghostty · "))
        #expect(!old.subtitle.contains(now.addingTimeInterval(-3 * 86400).formatted(.dateTime.month(.abbreviated))))

        var kyiv = Calendar(identifier: .gregorian)
        kyiv.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        let evening = kyiv.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 21, minute: 54))!
        let nextDay = kyiv.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 9))!
        #expect(ClipboardMenuRow.time(evening, now: nextDay, calendar: kyiv, locale: Locale(identifier: "uk_UA")) == "19.11 21:54")

        let dictated = entry(.diduny, text: "x", app: nil)
        #expect(ClipboardMenuRow(dictated, now: now, calendar: calendar).subtitle.hasPrefix("Dictated · "))
    }

    @Test("a files row is disabled, and says so, only when none of its files exist")
    func menuRowAvailability() {
        let files = entry(.files, paths: ["/a/here.txt", "/a/gone.txt"])
        let someLeft = ClipboardMenuRow(files, fileExists: { $0 == "/a/here.txt" })
        #expect(someLeft.isAvailable)

        let none = ClipboardMenuRow(files, fileExists: { _ in false })
        #expect(!none.isAvailable)
        #expect(none.subtitle == "Moved or deleted")

        #expect(ClipboardMenuRow(entry(.text, text: "x"), fileExists: { _ in false }).isAvailable)
    }

    @Test("the list is as tall as its rows up to the visible count")
    func menuListSize() {
        #expect(ClipboardMenuList.size(count: 3, visibleRows: 10).height == 3 * ClipboardMenuList.rowHeight)
        #expect(ClipboardMenuList.size(count: 248, visibleRows: 10).height == 10 * ClipboardMenuList.rowHeight)
    }
}
