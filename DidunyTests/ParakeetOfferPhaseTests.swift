@testable import Diduny
import Testing

/// The Ready screen's Parakeet V3 card (onboarding-parakeet.md "States").
struct ParakeetOfferPhaseTests {
    private func phase(
        supported: Bool = true, downloadedWhenShown: Bool = false, skipped: Bool = false, _ state: ModelDownloadState
    ) -> ParakeetOfferPhase {
        .resolve(isSupportedHardware: supported, downloadedWhenShown: downloadedWhenShown, skipped: skipped, state: state)
    }

    @Test func intelHidesTheOffer() {
        #expect(phase(supported: false, .notDownloaded) == .hidden)
    }

    @Test func alreadyDownloadedWhenShownHidesTheOffer() {
        #expect(phase(downloadedWhenShown: true, .downloaded) == .hidden)
    }

    @Test func mapsTheDownloadStates() {
        #expect(phase(.notDownloaded) == .notDownloaded)
        #expect(phase(.downloading(0.42)) == .downloading(0.42))
        #expect(phase(.failed("offline")) == .failed("offline"))
        #expect(phase(.downloaded) == .ready)
    }

    @Test func notNowShowsTheSkippedLineFromNotDownloadedAndFailed() {
        #expect(phase(skipped: true, .notDownloaded) == .skipped)
        #expect(phase(skipped: true, .failed("offline")) == .skipped)
    }

    @Test func aRunningDownloadWinsOverSkipped() {
        #expect(phase(skipped: true, .downloading(0.1)) == .downloading(0.1))
        #expect(phase(skipped: true, .downloaded) == .ready)
    }

    @Test func accessibilityValuesMatchTheDesign() {
        let values = [ParakeetOfferPhase.notDownloaded, .downloading(0), .failed(""), .ready, .skipped].map(\.accessibilityID)
        #expect(values == ["notDownloaded", "downloading", "failed", "ready", "skipped"])
    }
}
