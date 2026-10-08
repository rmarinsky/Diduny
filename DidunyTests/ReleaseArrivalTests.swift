import XCTest
@testable import Diduny

final class ReleaseHighlightsTests: XCTestCase {
    func testDecodePreservesCuratedHighlightOrder() throws {
        let data = Data(
            #"{"schemaVersion":1,"headline":"A clearer update","highlights":["First","Second","Third"]}"#.utf8
        )

        let highlights = try JSONDecoder().decode(ReleaseHighlights.self, from: data)

        XCTAssertEqual(highlights.schemaVersion, 1)
        XCTAssertEqual(highlights.headline, "A clearer update")
        XCTAssertEqual(highlights.highlights, ["First", "Second", "Third"])
    }

    func testDecodeRejectsUnsupportedOrEmptyPayloads() {
        let invalidPayloads = [
            #"{"schemaVersion":2,"headline":"Headline","highlights":["One"]}"#,
            #"{"schemaVersion":1,"headline":"   ","highlights":["One"]}"#,
            #"{"schemaVersion":1,"headline":"Headline","highlights":[]}"#,
            #"{"schemaVersion":1,"headline":"Headline","highlights":["One","Two","Three","Four"]}"#,
            #"{"schemaVersion":1,"headline":"Headline","highlights":[" "]}"#,
        ]

        for payload in invalidPayloads {
            XCTAssertThrowsError(
                try JSONDecoder().decode(ReleaseHighlights.self, from: Data(payload.utf8)),
                "Expected payload to be rejected: \(payload)"
            )
        }
    }

    func testLoadHidesMissingAndMalformedContent() throws {
        XCTAssertNil(ReleaseHighlights.load(from: nil))

        let malformedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-highlights-\(UUID().uuidString).json")
        try Data(#"{"schemaVersion":1}"#.utf8).write(to: malformedURL)
        defer { try? FileManager.default.removeItem(at: malformedURL) }

        XCTAssertNil(ReleaseHighlights.load(from: malformedURL))
    }

    func testBundledPayloadMatchesCuratedReleaseCopy() throws {
        let highlights = try XCTUnwrap(ReleaseHighlights.bundled())

        XCTAssertEqual(highlights.headline, "Translate voice in one direction")
        XCTAssertEqual(
            highlights.highlights,
            [
                "Voice translation always uses your selected output language, including mixed-language speech.",
                "Keep words already spoken in the output language without reversing translation.",
                "Recovered voice recordings retain their output language and source-language hints.",
            ]
        )
    }
}

@MainActor
final class UpdateArrivalStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "UpdateArrivalStateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFreshInstallRecordsVersionWithoutPendingNotice() {
        let state = UpdateArrivalState(defaults: defaults)

        state.recordLaunch(version: "2.1.0", isFreshInstall: true)

        XCTAssertEqual(state.highestLaunchedVersion, "2.1.0")
        XCTAssertNil(state.pendingReleaseLine)
    }

    func testNewMajorMinorLineCreatesPersistentPendingNotice() {
        defaults.set("2.1.4", forKey: UpdateArrivalState.highestLaunchedVersionKey)
        let state = UpdateArrivalState(defaults: defaults)

        state.recordLaunch(version: "2.2.0", isFreshInstall: false)

        XCTAssertEqual(state.highestLaunchedVersion, "2.2.0")
        XCTAssertEqual(state.pendingReleaseLine, "2.2")
        XCTAssertEqual(UpdateArrivalState(defaults: defaults).pendingReleaseLine, "2.2")

        state.dismissPendingRelease()
        state.recordLaunch(version: "3.0.0", isFreshInstall: false)
        XCTAssertEqual(state.pendingReleaseLine, "3.0")
    }

    func testEstablishedInstallWithoutUpdateStateShowsCurrentReleaseLine() {
        let state = UpdateArrivalState(defaults: defaults)

        state.recordLaunch(version: "2.1.0", isFreshInstall: false)

        XCTAssertEqual(state.highestLaunchedVersion, "2.1.0")
        XCTAssertEqual(state.pendingReleaseLine, "2.1")
    }

    func testInterruptedUpdatePersistsPendingNoticeForNextLaunch() throws {
        let interruptedDefaults = try XCTUnwrap(
            InterruptingUserDefaults(suiteName: suiteName)
        )
        interruptedDefaults.set(
            "2.1.4",
            forKey: UpdateArrivalState.highestLaunchedVersionKey
        )
        interruptedDefaults.writesRemaining = 1
        let state = UpdateArrivalState(defaults: interruptedDefaults)

        state.recordLaunch(version: "2.2.0", isFreshInstall: false)

        let relaunchedState = UpdateArrivalState(defaults: interruptedDefaults)
        XCTAssertEqual(relaunchedState.pendingReleaseLine, "2.2")
        XCTAssertEqual(relaunchedState.highestLaunchedVersion, "2.1.4")
    }

    func testPatchDowngradeIdempotencyAndDismissalDoNotResurfaceNotice() {
        defaults.set("2.2.0", forKey: UpdateArrivalState.highestLaunchedVersionKey)
        defaults.set("2.2", forKey: UpdateArrivalState.pendingReleaseLineKey)
        let state = UpdateArrivalState(defaults: defaults)

        state.recordLaunch(version: "2.2.1", isFreshInstall: false)
        XCTAssertEqual(state.highestLaunchedVersion, "2.2.1")
        XCTAssertEqual(state.pendingReleaseLine, "2.2")

        state.dismissPendingRelease()
        state.recordLaunch(version: "2.2.1", isFreshInstall: false)
        state.recordLaunch(version: "2.1.9", isFreshInstall: false)
        state.recordLaunch(version: "2.2.2", isFreshInstall: false)

        XCTAssertEqual(state.highestLaunchedVersion, "2.2.2")
        XCTAssertNil(state.pendingReleaseLine)
        XCTAssertNil(defaults.object(forKey: UpdateArrivalState.pendingReleaseLineKey))
    }

    func testUnavailableContentDoesNotClearPendingNotice() {
        defaults.set("2.2", forKey: UpdateArrivalState.pendingReleaseLineKey)
        let state = UpdateArrivalState(defaults: defaults)

        XCTAssertNil(ReleaseHighlights.load(from: nil))
        XCTAssertEqual(state.pendingReleaseLine, "2.2")
    }
}

private final class InterruptingUserDefaults: UserDefaults {
    var writesRemaining = Int.max

    override func set(_ value: Any?, forKey defaultName: String) {
        guard writesRemaining > 0 else { return }
        writesRemaining -= 1
        super.set(value, forKey: defaultName)
    }
}
