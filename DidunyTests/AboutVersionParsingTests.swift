import Testing
@testable import Diduny

@MainActor
struct AboutVersionParsingTests {
    @Test func readsShortVersionAttribute() {
        let xml = #"<enclosure sparkle:version="12" sparkle:shortVersionString="1.15.0" url="x"/>"#
        #expect(AboutSettingsView.extractLatestVersion(from: xml) == "1.15.0")
    }

    @Test func fallsBackToBuildAttribute() {
        let xml = #"<enclosure sparkle:version="12" url="x"/>"#
        #expect(AboutSettingsView.extractLatestVersion(from: xml) == "12")
    }

    @Test func readsTagForm() {
        let xml = "<item><sparkle:shortVersionString>2.0.1</sparkle:shortVersionString></item>"
        #expect(AboutSettingsView.extractLatestVersion(from: xml) == "2.0.1")
    }

    @Test func returnsNilWithoutVersion() {
        #expect(AboutSettingsView.extractLatestVersion(from: "<rss/>") == nil)
    }
}
