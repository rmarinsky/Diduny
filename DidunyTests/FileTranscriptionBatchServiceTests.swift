import AVFoundation
@testable import Diduny
import XCTest

final class YouTubeRemoteMediaSourceTests: XCTestCase {
    func test_normalize_acceptsWatchShareShortsAndParameterizedURLs() throws {
        let urls = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ?t=42",
            "https://youtube.com/shorts/dQw4w9WgXcQ?feature=share",
            "https://m.youtube.com/watch?list=PL123&v=dQw4w9WgXcQ"
        ]

        let sources = try urls.map(YouTubeRemoteMediaSource.normalize)

        XCTAssertEqual(Set(sources.map(\.mediaID)), ["dQw4w9WgXcQ"])
        XCTAssertEqual(
            Set(sources.map(\.canonicalURL.absoluteString)),
            ["https://www.youtube.com/watch?v=dQw4w9WgXcQ"]
        )
    }

    func test_normalize_rejectsPlaylistOtherProviderAndMalformedVideoID() {
        XCTAssertThrowsError(try YouTubeRemoteMediaSource.normalize("https://youtube.com/playlist?list=PL123"))
        XCTAssertThrowsError(try YouTubeRemoteMediaSource.normalize("https://vimeo.com/123456"))
        XCTAssertThrowsError(try YouTubeRemoteMediaSource.normalize("https://youtu.be/not-valid"))
    }

    func test_normalizeBatch_removesRepeatedCanonicalVideoIDs() throws {
        let sources = try YouTubeRemoteMediaSource.normalizeBatch(
            """
            https://youtu.be/dQw4w9WgXcQ
            https://youtube.com/watch?v=dQw4w9WgXcQ&t=10
            https://youtube.com/shorts/aqz-KE-bpKQ
            """
        )

        XCTAssertEqual(sources.map(\.mediaID), ["dQw4w9WgXcQ", "aqz-KE-bpKQ"])
    }

    func test_validateBatch_reportsValidDuplicateAndInvalidLines() {
        let validation = YouTubeRemoteMediaSource.validateBatch(
            """
            https://youtu.be/dQw4w9WgXcQ
            https://youtube.com/watch?v=dQw4w9WgXcQ&t=10
            not-a-youtube-url
            https://youtube.com/shorts/aqz-KE-bpKQ
            """
        )

        XCTAssertEqual(validation.sources.map(\.mediaID), ["dQw4w9WgXcQ", "aqz-KE-bpKQ"])
        XCTAssertEqual(validation.duplicateCount, 1)
        XCTAssertEqual(validation.invalidValues, ["not-a-youtube-url"])
    }

    func test_validateBatch_reportsURLsAlreadyInBatchAsDuplicates() {
        let validation = YouTubeRemoteMediaSource.validateBatch(
            "https://youtu.be/dQw4w9WgXcQ",
            excludingMediaIDs: ["dQw4w9WgXcQ"]
        )

        XCTAssertTrue(validation.sources.isEmpty)
        XCTAssertEqual(validation.duplicateCount, 1)
    }

    func test_captionSelection_prefersAuthoredOriginalLanguageThenAutomatic() {
        let authored = RemoteCaptionTrack(
            languageCode: "uk",
            displayName: "Ukrainian",
            kind: .authored
        )
        let automatic = RemoteCaptionTrack(
            languageCode: "uk-orig",
            displayName: "Ukrainian (auto-generated)",
            kind: .automatic
        )

        XCTAssertEqual(
            RemoteCaptionTrack.preferred(
                authored: [authored],
                automatic: [automatic],
                originalLanguageCode: "uk"
            ),
            authored
        )
        XCTAssertEqual(
            RemoteCaptionTrack.preferred(
                authored: [],
                automatic: [automatic],
                originalLanguageCode: "uk"
            ),
            automatic
        )
        XCTAssertNil(
            RemoteCaptionTrack.preferred(
                authored: [
                    RemoteCaptionTrack(
                        languageCode: "de",
                        displayName: "German",
                        kind: .authored
                    )
                ],
                automatic: [],
                originalLanguageCode: "uk"
            )
        )
        XCTAssertNil(
            RemoteCaptionTrack.preferred(
                authored: [authored],
                automatic: [automatic],
                originalLanguageCode: nil
            )
        )
    }

    func test_extractorFailureClassificationDistinguishesPrivateVideoFromExpiredSession() {
        XCTAssertEqual(
            BundledRemoteMediaExtractor.classifyFailure(Data("Private video".utf8)),
            .sourceUnavailable
        )
        XCTAssertEqual(
            BundledRemoteMediaExtractor.classifyFailure(Data("Sign in to confirm".utf8)),
            .authorizationRequired
        )
    }

    func test_metadataDecoder_selectsCompatibleAudioOnlyFormatAndOriginalCaptions() throws {
        let json = """
        {
          "id": "dQw4w9WgXcQ",
          "title": "A video",
          "uploader": "A channel",
          "description": "Source description",
          "duration": 125.5,
          "original_language": "uk",
          "is_live": false,
          "availability": "public",
          "formats": [
            {"format_id":"video","ext":"mp4","acodec":"none","vcodec":"avc1","tbr":900},
            {"format_id":"audio-low","ext":"m4a","acodec":"mp4a.40.2","vcodec":"none","abr":64},
            {"format_id":"audio-best","ext":"m4a","acodec":"mp4a.40.2","vcodec":"none","abr":128}
          ],
          "subtitles": {"uk":[{"name":"Ukrainian","ext":"vtt"}]},
          "automatic_captions": {"uk-orig":[{"name":"Ukrainian (auto-generated)","ext":"vtt"}]}
        }
        """
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")

        let metadata = try RemoteMediaMetadata.decodeYTDLPJSON(Data(json.utf8), expectedSource: source)

        XCTAssertEqual(metadata.source.title, "A video")
        XCTAssertEqual(metadata.source.channelName, "A channel")
        XCTAssertEqual(metadata.source.description, "Source description")
        XCTAssertEqual(metadata.audioFormatID, "audio-best")
        XCTAssertEqual(metadata.preferredCaption?.kind, .authored)
        XCTAssertEqual(metadata.durationSeconds, 125.5, accuracy: 0.001)
    }

    func test_metadataDecoder_rejectsLiveAndMissingAudioOnlyFormats() throws {
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")
        let liveJSON = """
        {"id":"dQw4w9WgXcQ","title":"Live","duration":1,"is_live":true,"formats":[]}
        """
        let videoOnlyJSON = """
        {"id":"dQw4w9WgXcQ","title":"Video","duration":1,"is_live":false,
         "formats":[{"format_id":"video","ext":"mp4","acodec":"none","vcodec":"avc1"}]}
        """

        XCTAssertThrowsError(try RemoteMediaMetadata.decodeYTDLPJSON(Data(liveJSON.utf8), expectedSource: source)) {
            XCTAssertEqual($0 as? RemoteMediaExtractorError, .unsupportedLiveStream)
        }
        XCTAssertThrowsError(try RemoteMediaMetadata.decodeYTDLPJSON(
            Data(videoOnlyJSON.utf8),
            expectedSource: source
        )) {
            XCTAssertEqual($0 as? RemoteMediaExtractorError, .noAudioOnlyStream)
        }
    }

    func test_webVTTParser_removesTimingMarkupAndRepeatedCaptionFrames() {
        let vtt = """
        WEBVTT

        00:00:00.000 --> 00:00:01.000
        <c>Привіт</c>

        00:00:01.000 --> 00:00:02.000
        <c>Привіт</c>

        00:00:02.000 --> 00:00:03.000
        світе
        """

        XCTAssertEqual(WebVTTTranscriptParser.parse(vtt), "Привіт\nсвіте")
    }

    func test_chromiumSessionDiscovery_keepsSelectedBrowserAndExistingProfiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DidunyChromeProfiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Default"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Profile 2"),
            withIntermediateDirectories: true
        )
        let localState = """
        {"profile":{"info_cache":{
          "Default":{"name":"Roman"},
          "Profile 2":{"name":"Work"},
          "Profile 9":{"name":"Deleted"}
        }}}
        """
        try Data(localState.utf8).write(to: root.appendingPathComponent("Local State"))

        let sessions = BrowserSessionStore.discoverChromium(browser: .edge, in: root)

        XCTAssertEqual(sessions.map(\.browser), [.edge, .edge])
        XCTAssertEqual(sessions.map(\.profileID), ["Default", "Profile 2"])
        XCTAssertEqual(sessions.map(\.profileName), ["Roman", "Work"])
        XCTAssertEqual(sessions.map(\.cookieArgument), ["edge:Default", "edge:Profile 2"])
    }

    func test_firefoxSessionDiscovery_supportsZenProfilePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DidunyZenProfiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Profiles/current"),
            withIntermediateDirectories: true
        )
        let profilesINI = """
        [Profile0]
        Name=Roman
        IsRelative=1
        Path=Profiles/current

        [Profile1]
        Name=Deleted
        IsRelative=1
        Path=Profiles/deleted
        """
        try Data(profilesINI.utf8).write(to: root.appendingPathComponent("profiles.ini"))

        let sessions = BrowserSessionStore.discoverFirefox(browser: .zen, in: root)

        XCTAssertEqual(sessions.map(\.displayName), ["Zen — Roman"])
        XCTAssertEqual(
            sessions.map(\.cookieArgument),
            ["firefox:\(root.appendingPathComponent("Profiles/current").path)"]
        )
    }

    func test_browserSessionDiscovery_listsProfilesForInstalledBrowsers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DidunyBrowserSessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, profileName) in [
            ("Google/Chrome", "Roman"),
            ("Microsoft Edge", "Work"),
        ] {
            let directory = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("Default"),
                withIntermediateDirectories: true
            )
            let localState = """
            {"profile":{"info_cache":{"Default":{"name":"\(profileName)"}}}}
            """
            try Data(localState.utf8).write(to: directory.appendingPathComponent("Local State"))
        }
        let zen = root.appendingPathComponent("zen")
        try FileManager.default.createDirectory(
            at: zen.appendingPathComponent("Profiles/current"),
            withIntermediateDirectories: true
        )
        try Data("[Profile0]\nName=Default\nIsRelative=1\nPath=Profiles/current".utf8)
            .write(to: zen.appendingPathComponent("profiles.ini"))

        let sessions = BrowserSessionStore.discover(
            installedBrowsers: [.chrome, .edge, .safari, .zen],
            applicationSupportDirectory: root
        )

        XCTAssertEqual(
            sessions.map(\.displayName),
            ["Google Chrome — Roman", "Microsoft Edge — Work", "Safari", "Zen — Default"]
        )
    }

    func test_browserSessionSelection_prefersSavedSessionAndFallsBackToLegacyChromeProfile() {
        let chrome = BrowserSession(browser: .chrome, profileID: "Default", profileName: "Roman")
        let edge = BrowserSession(browser: .edge, profileID: "Default", profileName: "Work")
        let sessions = [chrome, edge]

        XCTAssertEqual(
            BrowserSessionStore.selected(
                from: sessions,
                selectionID: edge.selectionID,
                legacyChromeProfileID: nil
            ),
            edge
        )
        XCTAssertEqual(
            BrowserSessionStore.selected(
                from: sessions,
                selectionID: nil,
                legacyChromeProfileID: "Default"
            ),
            chrome
        )
    }

    func test_runtimeArguments_useSelectedBrowserSessionBundledDenoAndExactAudioFormat() throws {
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")
        let session = BrowserSession(browser: .edge, profileID: "Profile 2", profileName: "Work")
        let denoURL = URL(fileURLWithPath: "/Applications/Diduny.app/Contents/Resources/deno")

        let metadata = BundledRemoteMediaExtractor.metadataArguments(
            source: source,
            session: session,
            denoURL: denoURL
        )
        let download = BundledRemoteMediaExtractor.downloadArguments(
            source: source,
            session: session,
            denoURL: denoURL,
            audioFormatID: "audio-best",
            outputTemplate: "/tmp/source.%(ext)s"
        )

        XCTAssertTrue(metadata.contains("edge:Profile 2"))
        XCTAssertTrue(metadata.contains("deno:\(denoURL.path)"))
        XCTAssertTrue(metadata.contains("--dump-single-json"))
        XCTAssertTrue(download.contains("audio-best"))
        XCTAssertTrue(download.contains("--no-playlist"))
        XCTAssertFalse(download.contains(where: { $0.contains("bestvideo") }))
    }

    @MainActor
    func test_metadataFallsBackToPublicAccessWhenChromeCookieDatabaseIsUnreadable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DidunyRemoteFallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-yt-dlp")
        let script = """
        #!/bin/sh
        case " $* " in
          *" --cookies-from-browser "*)
            echo "ERROR: no such table: meta" >&2
            exit 1
            ;;
        esac
        printf '%s\\n' '{"id":"dQw4w9WgXcQ","title":"Public video","duration":1,"formats":[{"format_id":"audio","ext":"m4a","acodec":"mp4a.40.2","vcodec":"none"}]}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let extractor = BundledRemoteMediaExtractor(
            ytDLPURL: executable,
            denoURL: executable,
            temporaryDirectory: root
        )
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")

        let metadata = try await extractor.metadata(
            for: source,
            session: BrowserSession(browser: .chrome, profileID: "Profile 1", profileName: "Personal")
        )

        XCTAssertEqual(metadata.source.title, "Public video")
        XCTAssertEqual(metadata.audioFormatID, "audio")
    }

    func test_remoteDuplicateMatcher_prefersProviderIdentityAndSupportsLegacyTitleDurationFallback() throws {
        let source = try RemoteMediaSourceMetadata(
            provider: YouTubeRemoteMediaSource.provider,
            mediaID: "dQw4w9WgXcQ",
            canonicalURL: XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")),
            title: "A Useful Video",
            channelName: "Channel"
        )
        let exact = makeRemoteRecording(
            sourceFileName: "different.mov",
            duration: 10,
            remoteSource: source
        )
        var legacy = makeRemoteRecording(
            sourceFileName: "A Useful Video.mp4",
            duration: 121.4,
            remoteSource: nil
        )

        XCTAssertTrue(RemoteRecordingDuplicateMatcher.matches(exact, metadata: source, durationSeconds: 999))
        XCTAssertTrue(RemoteRecordingDuplicateMatcher.matches(legacy, metadata: source, durationSeconds: 120))
        XCTAssertFalse(RemoteRecordingDuplicateMatcher.matches(legacy, metadata: source, durationSeconds: 124))

        legacy.status = .failed
        legacy.transcriptionText = nil
        legacy.sourceCaptionArtifacts = [
            TranscriptArtifact(
                text: "Reusable captions",
                languageCode: "en",
                provenance: .youtubeAuthored
            )
        ]
        XCTAssertTrue(RemoteRecordingDuplicateMatcher.matches(legacy, metadata: source, durationSeconds: 120))
    }

    private func makeRemoteRecording(
        sourceFileName: String,
        duration: TimeInterval,
        remoteSource: RemoteMediaSourceMetadata?
    ) -> Recording {
        Recording(
            id: UUID(),
            createdAt: Date(),
            type: .fileTranscription,
            audioFileName: "audio.m4a",
            durationSeconds: duration,
            fileSizeBytes: 10,
            status: .translated,
            transcriptionText: "Existing",
            sourceDevice: nil,
            sourceFileName: sourceFileName,
            remoteSource: remoteSource
        )
    }
}

@MainActor
final class YouTubeRemoteMediaE2ETests: XCTestCase {
    func test_examplePublicURLsRetrieveAudioWithSelectedChromeProfile() async throws {
        guard ProcessInfo.processInfo.environment["DIDUNY_YOUTUBE_E2E"] == "1" else {
            throw XCTSkip("Set DIDUNY_YOUTUBE_E2E=1 to run live YouTube acquisition")
        }
        let profileID = ProcessInfo.processInfo.environment["DIDUNY_CHROME_PROFILE"] ?? "Profile 1"
        let profile = ChromeProfile(id: profileID, name: profileID)
        let extractor = BundledRemoteMediaExtractor()
        let urls = [
            "https://www.youtube.com/watch?v=434cG4g5KLE",
            "https://youtu.be/Zdk_YgK0i58"
        ]

        for rawURL in urls {
            let source = try YouTubeRemoteMediaSource.normalize(rawURL)
            let metadata = try await extractor.metadata(for: source, session: profile)
            let downloaded = try await extractor.downloadAudio(
                for: source,
                metadata: metadata,
                session: profile,
                onProgress: { _ in }
            )
            defer { downloaded.removeTemporaryFiles() }
            let values = try downloaded.fileURL.resourceValues(forKeys: [.fileSizeKey])
            XCTAssertGreaterThan(values.fileSize ?? 0, 0, rawURL)
        }
    }
}

@MainActor
final class FileTranscriptionBatchServiceTests: XCTestCase {
    func test_importedMediaSettingsAlwaysUseLocalProvider() {
        XCTAssertEqual(FileTranscriptionSettingsSnapshot.current().provider, .local)
    }

    func test_add_skipsDuplicateURLsWithinActiveBatch() {
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(),
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        let first = URL(fileURLWithPath: "/tmp/first.mov")

        service.add(urls: [first, first, URL(fileURLWithPath: "/tmp/second.mp3")])

        XCTAssertEqual(service.items.map(\.sourceURL), [first, URL(fileURLWithPath: "/tmp/second.mp3")])
    }

    func test_addRemoteSources_skipsRepeatedCanonicalVideoIDs() throws {
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(),
            remoteExtractor: BatchTestRemoteExtractor(),
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")

        service.add(remoteSources: [source, source])

        XCTAssertEqual(service.items.count, 1)
        XCTAssertEqual(service.items.first?.remoteSource?.mediaID, "dQw4w9WgXcQ")
    }

    func test_beginRemoteBatchRequiresAuthorizedBrowserSessionBeforeAddingWork() throws {
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(),
            remoteExtractor: BatchTestRemoteExtractor(),
            chromeProfile: { nil },
            remoteMediaAuthorized: { true },
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")

        let accepted = service.beginBatch(remoteSources: [source])

        XCTAssertFalse(accepted)
        XCTAssertTrue(service.items.isEmpty)
        XCTAssertEqual(service.batchError, "Select a browser session to transcribe YouTube URLs.")
    }

    func test_remoteAuthorizationPausesWholeBatchAndExplicitRetryCompletes() async throws {
        let extractor = BatchTestRemoteExtractor(metadataAuthorizationFailureCount: 1)
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(),
            remoteExtractor: extractor,
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        let first = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")
        let second = try YouTubeRemoteMediaSource.normalize("https://youtu.be/aqz-KE-bpKQ")

        service.beginBatch(remoteSources: [first, second])
        try await waitUntil {
            !service.isProcessing
                && service.items.allSatisfy { $0.status == .authorizationPaused }
        }

        XCTAssertEqual(extractor.downloadCallCount, 0)
        service.retryAuthorization()
        try await waitUntil { !service.isProcessing && service.completedCount == 2 }

        XCTAssertEqual(service.items.map(\.status), [.completed, .completed])
        XCTAssertGreaterThanOrEqual(extractor.metadataCallCount, 3)
    }

    func test_remoteAuthorizationPauseIsPersistedForRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchAuthorizationPersistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(),
            remoteExtractor: BatchTestRemoteExtractor(captionAuthorizationFailureCount: 1),
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            batchPersistence: batchStore,
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")

        service.beginBatch(remoteSources: [source])
        try await waitUntil { service.items.first?.status == .authorizationPaused }

        let reloaded = try TranscriptionBatchStorage(baseDirectory: directory)
        XCTAssertEqual(reloaded.batches.first?.workItems?.first?.status, .authorizationPaused)
    }

    func test_stopBatchDuringRemotePreflightMarksItemsCancelledWithoutAcquisition() async throws {
        let extractor = BatchTestRemoteExtractor(metadataDelay: .milliseconds(500))
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(),
            remoteExtractor: extractor,
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")

        service.beginBatch(remoteSources: [source])
        try await waitUntil { service.items.first?.status == .checkingLink }
        service.cancelAll()
        try await waitUntil { !service.isProcessing }

        XCTAssertEqual(service.items.first?.status, .cancelled)
        XCTAssertEqual(extractor.downloadCallCount, 0)
    }

    func test_stopBatchCancelsMetadataRequestsWaitingForPermit() async throws {
        let extractor = BatchTestRemoteExtractor(metadataDelay: .milliseconds(500))
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(),
            remoteExtractor: extractor,
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        let ids = ["dQw4w9WgXcQ", "aqz-KE-bpKQ", "M7lc1UVf-VE", "jNQXAC9IVRw"]
        let sources = try ids.map {
            try YouTubeRemoteMediaSource.normalize("https://youtu.be/\($0)")
        }

        service.beginBatch(remoteSources: sources)
        try await waitUntil { extractor.metadataCallCount == 3 }
        service.cancelAll()
        try await waitUntil { !service.isProcessing }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(extractor.metadataCallCount, 3)
        XCTAssertEqual(extractor.downloadCallCount, 0)
        XCTAssertTrue(service.items.allSatisfy { $0.status == .cancelled })
    }

    func test_remoteCaptionSurvivesGeneratedTranscriptFailureAsPartialResult() async throws {
        let caption = TranscriptArtifact(
            text: "Provider captions",
            languageCode: "uk",
            provenance: .youtubeAuthored
        )
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(failureCount: 1),
            recordingStore: BatchTestRecordingStore(),
            remoteExtractor: BatchTestRemoteExtractor(caption: caption),
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")

        service.beginBatch(remoteSources: [source])
        try await waitUntil { !service.isProcessing && service.finishedCount == 1 }

        XCTAssertEqual(service.items.first?.status, .partialResult)
        XCTAssertEqual(service.items.first?.sourceCaptionArtifacts, [caption])
        XCTAssertNil(service.items.first?.transcriptionText)
    }

    func test_remoteTranscriptionPersistsTimedPhraseSegments() async throws {
        let segments = [
            TimedTranscriptSegment(
                startMilliseconds: 1200,
                endMilliseconds: 2000,
                text: "First thought."
            )
        ]
        let transcriber = BatchTestTranscriber(
            transcript: GeneratedTranscript(text: "First thought.", segments: segments)
        )
        let store = BatchTestRecordingStore(storesRemoteAudio: true)
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: store,
            remoteExtractor: BatchTestRemoteExtractor(),
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")

        service.beginBatch(remoteSources: [source])
        try await waitUntil { !service.isProcessing && service.finishedCount == 1 }

        XCTAssertEqual(store.completedTranscript?.text, "First thought.")
        XCTAssertEqual(store.completedTranscript?.segments, segments)
    }

    func test_remoteCaptionRetryDoesNotRegenerateCompletedTranscript() async throws {
        let caption = TranscriptArtifact(
            text: "Provider captions",
            languageCode: "uk",
            provenance: .youtubeAuthored
        )
        let extractor = BatchTestRemoteExtractor(
            caption: caption,
            captionFailureCount: 1
        )
        let transcriber = BatchTestTranscriber()
        let store = BatchTestRecordingStore(storesRemoteAudio: true)
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: store,
            remoteExtractor: extractor,
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")

        service.beginBatch(remoteSources: [source])
        try await waitUntil { !service.isProcessing && service.finishedCount == 1 }
        XCTAssertEqual(service.items.first?.status, .partialResult)
        XCTAssertNotNil(service.items.first?.transcriptionText)

        service.retryFailed()
        try await waitUntil { !service.isProcessing && service.completedCount == 1 }

        XCTAssertEqual(transcriber.transcribedFileNames.count, 1)
        XCTAssertEqual(service.items.first?.sourceCaptionArtifacts, [caption])
        XCTAssertEqual(store.updatedCaptionArtifacts, [caption])
    }

    func test_remoteAcquisitionNeverExceedsTwoConcurrentDownloads() async throws {
        let extractor = BatchTestRemoteExtractor(downloadDelay: .milliseconds(80))
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(delay: .milliseconds(80)),
            recordingStore: BatchTestRecordingStore(),
            remoteExtractor: extractor,
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        let ids = ["dQw4w9WgXcQ", "aqz-KE-bpKQ", "M7lc1UVf-VE", "jNQXAC9IVRw"]
        let sources = try ids.map {
            try YouTubeRemoteMediaSource.normalize("https://youtu.be/\($0)")
        }

        service.beginBatch(remoteSources: sources)
        try await waitUntil { !service.isProcessing && service.completedCount == 4 }

        XCTAssertEqual(extractor.maximumConcurrentDownloadCount, 2)
    }

    func test_addRemoteSource_reusesProviderIdentityWithoutAcquisition() throws {
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")
        let recordingID = UUID()
        let extractor = BatchTestRemoteExtractor()
        let caption = TranscriptArtifact(
            text: "Existing captions",
            languageCode: "en",
            provenance: .youtubeAuthored
        )
        let store = BatchTestRecordingStore(
            remoteDuplicate: BatchTranscriptionDuplicate(
                recordingID: recordingID,
                transcriptionText: "Existing transcript",
                durationSeconds: 90,
                sourceCaptionArtifacts: [caption]
            ),
            matchingRemoteMediaID: source.mediaID
        )
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: store,
            remoteExtractor: extractor,
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.beginBatch(remoteSources: [source])

        XCTAssertEqual(service.items.first?.status, .duplicate)
        XCTAssertEqual(service.items.first?.recordingID, recordingID)
        XCTAssertEqual(extractor.metadataCallCount, 0)
    }

    func test_beginBatchPersistsReusedMembershipAndClosesFinishedBatch() throws {
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")
        let recordingID = UUID()
        let batchStore = BatchTestPersistence()
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(
                remoteDuplicate: BatchTranscriptionDuplicate(
                    recordingID: recordingID,
                    transcriptionText: "Existing transcript",
                    durationSeconds: 90,
                    sourceCaptionArtifacts: [
                        TranscriptArtifact(
                            text: "Captions",
                            languageCode: "en",
                            provenance: .youtubeAuthored
                        )
                    ]
                ),
                matchingRemoteMediaID: source.mediaID
            ),
            remoteExtractor: BatchTestRemoteExtractor(),
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            batchPersistence: batchStore,
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.beginBatch(
            remoteSources: [source],
            name: "Research",
            description: "Reused source",
            existingRecordingIDs: []
        )

        XCTAssertEqual(batchStore.createdName, "Research")
        XCTAssertEqual(batchStore.createdDescription, "Reused source")
        XCTAssertEqual(batchStore.recordingIDs, [recordingID])
        XCTAssertTrue(batchStore.didClose)
        XCTAssertEqual(service.lastCreatedBatchID, batchStore.batchID)

        service.add(urls: [URL(fileURLWithPath: "/tmp/late.m4a")])
        XCTAssertEqual(service.items.count, 1)
        XCTAssertEqual(service.items.first?.sourceURL.lastPathComponent, "late.m4a")
        XCTAssertEqual(batchStore.createCount, 2)
    }

    func test_beginBatchRejectsOverlappingBatch() async throws {
        let transcriber = BatchTestTranscriber(waitsForRelease: true)
        let batchStore = BatchTestPersistence()
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: BatchTestRecordingStore(),
            batchPersistence: batchStore,
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        XCTAssertTrue(service.beginBatch(urls: [URL(fileURLWithPath: "/tmp/first.m4a")]))
        try await waitUntil { transcriber.transcribedFileNames == ["first.m4a"] }
        XCTAssertEqual(service.activeBatchID, batchStore.batchID)
        let accepted = service.beginBatch(urls: [URL(fileURLWithPath: "/tmp/second.m4a")])

        XCTAssertFalse(accepted)
        XCTAssertEqual(batchStore.createCount, 1)
        XCTAssertEqual(service.items.map(\.sourceURL.lastPathComponent), ["first.m4a"])
        transcriber.releaseAll()
        try await waitUntil { !service.isProcessing }
    }

    func test_appendToActiveBatchAddsWorkWithoutOpeningAnotherBatch() async throws {
        let transcriber = BatchTestTranscriber(waitsForRelease: true)
        let batchStore = BatchTestPersistence()
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: BatchTestRecordingStore(),
            batchPersistence: batchStore,
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        XCTAssertTrue(service.beginBatch(urls: [URL(fileURLWithPath: "/tmp/first.m4a")]))
        try await waitUntil { transcriber.transcribedFileNames == ["first.m4a"] }

        let accepted = service.append(
            to: TranscriptionBatch(id: batchStore.batchID, name: "Active"),
            urls: [URL(fileURLWithPath: "/tmp/second.m4a")],
            remoteSources: [],
            existingRecordingIDs: []
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(batchStore.createCount, 1)
        XCTAssertEqual(
            service.items.map(\.sourceURL.lastPathComponent),
            ["first.m4a", "second.m4a"]
        )
        transcriber.releaseAll()
        try await waitUntil { transcriber.transcribedFileNames.count == 2 }
        transcriber.releaseAll()
        try await waitUntil { !service.isProcessing }
    }

    func test_beginBatchRejectsOverlapWhileFirstBatchIsPreflightBlocked() {
        let batchStore = BatchTestPersistence()
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(preflightError: "Offline"),
            recordingStore: BatchTestRecordingStore(),
            batchPersistence: batchStore,
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        XCTAssertTrue(service.beginBatch(urls: [URL(fileURLWithPath: "/tmp/first.m4a")]))
        let accepted = service.beginBatch(urls: [URL(fileURLWithPath: "/tmp/second.m4a")])

        XCTAssertFalse(accepted)
        XCTAssertEqual(batchStore.createCount, 1)
        XCTAssertEqual(service.items.map(\.sourceURL.lastPathComponent), ["first.m4a"])
    }

    func test_remoteRetryReusesDownloadedAudioAfterPreparationFailure() async throws {
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")
        let extractor = BatchTestRemoteExtractor()
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(failingSourceNames: ["dQw4w9WgXcQ.m4a"]),
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(),
            remoteExtractor: extractor,
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            batchPersistence: BatchTestPersistence(),
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.beginBatch(remoteSources: [source])
        try await waitUntil { !service.isProcessing }
        service.retryFailed()
        try await waitUntil { !service.isProcessing }

        XCTAssertEqual(extractor.downloadCallCount, 1)
    }

    func test_retryResumesSubmittedCloudJobWithoutUploadingAgain() async throws {
        let transcriber = BatchTestTranscriber(failureCount: 1)
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: BatchTestRecordingStore(),
            batchPersistence: BatchTestPersistence(),
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.beginBatch(urls: [URL(fileURLWithPath: "/tmp/upload.m4a")])
        try await waitUntil { !service.isProcessing }
        service.retryFailed()
        try await waitUntil { !service.isProcessing }

        XCTAssertEqual(transcriber.receivedResumeJobIDs, [nil, "test-job"])
    }

    func test_beginBatchCombinesFilesURLsAndExistingLibraryRecordingsInOrder() throws {
        let existingID = UUID()
        let fileID = UUID()
        let remoteID = UUID()
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")
        let batchStore = BatchTestPersistence()
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(
                duplicate: BatchTranscriptionDuplicate(
                    recordingID: fileID,
                    transcriptionText: "File",
                    durationSeconds: 1
                ),
                remoteDuplicate: BatchTranscriptionDuplicate(
                    recordingID: remoteID,
                    transcriptionText: "Remote",
                    durationSeconds: 1,
                    sourceCaptionArtifacts: [
                        TranscriptArtifact(
                            text: "Captions",
                            languageCode: "en",
                            provenance: .youtubeAuthored
                        )
                    ]
                ),
                matchingRemoteMediaID: source.mediaID
            ),
            remoteExtractor: BatchTestRemoteExtractor(),
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            batchPersistence: batchStore,
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.beginBatch(
            urls: [URL(fileURLWithPath: "/tmp/file.m4a")],
            remoteSources: [source],
            name: "Mixed",
            description: "",
            existingRecordingIDs: [existingID]
        )

        XCTAssertEqual(batchStore.recordingIDs, [existingID, fileID, remoteID])
        XCTAssertTrue(batchStore.didClose)
    }

    func test_appendToCompletedBatchReopensAndPreservesAllMembership() async throws {
        let existingID = UUID()
        let addedExistingID = UUID()
        let fileID = UUID()
        let remoteID = UUID()
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")
        let batchStore = BatchTestPersistence()
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(
                duplicate: BatchTranscriptionDuplicate(
                    recordingID: fileID,
                    transcriptionText: "File",
                    durationSeconds: 1
                ),
                remoteDuplicate: BatchTranscriptionDuplicate(
                    recordingID: remoteID,
                    transcriptionText: "Remote",
                    durationSeconds: 1,
                    sourceCaptionArtifacts: []
                ),
                matchingRemoteMediaID: source.mediaID
            ),
            remoteExtractor: BatchTestRemoteExtractor(),
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            batchPersistence: batchStore,
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        let batch = TranscriptionBatch(
            name: "Research",
            isProcessingClosed: true,
            recordingIDs: [existingID]
        )

        let accepted = service.append(
            to: batch,
            urls: [URL(fileURLWithPath: "/tmp/file.m4a")],
            remoteSources: [source],
            existingRecordingIDs: [addedExistingID]
        )

        XCTAssertTrue(accepted)
        try await waitUntil { batchStore.didClose }
        XCTAssertTrue(batchStore.didReopen)
        XCTAssertTrue(batchStore.didClose)
        XCTAssertEqual(batchStore.createCount, 0)
        XCTAssertEqual(batchStore.recordingIDs, [existingID, addedExistingID, fileID, remoteID])
    }

    func test_appendRemoteSourceRequiresRightsBeforeReopeningBatch() throws {
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")
        let batchStore = BatchTestPersistence()
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(),
            remoteExtractor: BatchTestRemoteExtractor(),
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            remoteMediaAuthorized: { false },
            batchPersistence: batchStore,
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        let accepted = service.append(
            to: TranscriptionBatch(name: "Research", isProcessingClosed: true),
            urls: [],
            remoteSources: [source],
            existingRecordingIDs: []
        )

        XCTAssertFalse(accepted)
        XCTAssertFalse(batchStore.didReopen)
        XCTAssertEqual(
            service.batchError,
            "Confirm that you own this content or have permission to transcribe it."
        )
    }

    func test_resumePersistedBatchReusesPreparedRecordingCheckpoint() async throws {
        let recordingID = UUID()
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")
        var item = BatchTranscriptionItem(remoteSource: source)
        item.recordingID = recordingID
        item.status = .failed
        item.errorMessage = "Offline"
        let batch = TranscriptionBatch(
            name: "Retry",
            isProcessingClosed: true,
            recordingIDs: [recordingID],
            workItems: [item]
        )
        let preparer = BatchTestPreparer()
        let batchStore = BatchTestPersistence()
        let service = FileTranscriptionBatchService(
            preparer: preparer,
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(
                existingRecordingID: recordingID,
                audioFileURL: URL(fileURLWithPath: "/tmp/saved.m4a")
            ),
            remoteExtractor: BatchTestRemoteExtractor(),
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            batchPersistence: batchStore,
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.resume(batch: batch)
        try await waitUntil { !service.isProcessing }

        XCTAssertEqual(preparer.preparedSourceNames, [])
        XCTAssertEqual(service.items.first?.status, .completed)
        XCTAssertTrue(batchStore.didReopen)
        XCTAssertTrue(batchStore.didClose)
    }

    func test_resumePersistedBatchRetriesOnlySelectedItem() async throws {
        var first = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/first.m4a"))
        first.status = .failed
        var second = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/second.m4a"))
        second.status = .failed
        let batch = TranscriptionBatch(
            name: "Retry one",
            isProcessingClosed: true,
            workItems: [first, second]
        )
        let transcriber = BatchTestTranscriber(waitsForRelease: true)
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: BatchTestRecordingStore(),
            batchPersistence: BatchTestPersistence(),
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.resume(batch: batch, retrying: [first.id])
        try await waitUntil { transcriber.transcribedFileNames == ["first.m4a"] }

        XCTAssertEqual(service.activeBatchID, batch.id)
        XCTAssertEqual(service.items.map(\.status), [.uploading, .failed])
        transcriber.releaseAll()
        try await waitUntil { !service.isProcessing }
    }

    func test_resumeDoesNotReplaceAnotherBlockedPersistentBatch() {
        let persistence = BatchTestPersistence()
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(preflightError: "Offline"),
            recordingStore: BatchTestRecordingStore(),
            batchPersistence: persistence,
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        service.beginBatch(
            urls: [URL(fileURLWithPath: "/tmp/first.m4a")],
            remoteSources: [],
            name: "First",
            description: "",
            existingRecordingIDs: []
        )
        var item = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/second.m4a"))
        item.status = .failed
        let second = TranscriptionBatch(name: "Second", isProcessingClosed: true, workItems: [item])

        XCTAssertFalse(service.canResume(batch: second))
        service.resume(batch: second)

        XCTAssertEqual(service.items.map(\.sourceURL.lastPathComponent), ["first.m4a"])
    }

    func test_resumedTrimmedBatchTranscribesSelectedSamplesAndCleansTemporaryAudio() async throws {
        for remote in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let audioURL = directory.appendingPathComponent("original.wav")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
            do {
                let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
                buffer.frameLength = 16000
                for index in 0..<16000 { buffer.floatChannelData![0][index] = 0.25 }
                try file.write(from: buffer)
            }
            let originalBytes = try Data(contentsOf: audioURL)
            let recordingID = UUID()
            var recording = Recording(id: recordingID, createdAt: Date(), type: .fileTranscription,
                audioFileName: "original.wav", durationSeconds: 2, fileSizeBytes: Int64(originalBytes.count),
                status: .failed, sourceDevice: nil)
            recording.trimRange = AudioTrimRange(startSeconds: 0.5, endSeconds: 1.25)
            var item = remote
                ? BatchTranscriptionItem(remoteSource: try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ"))
                : BatchTranscriptionItem(sourceURL: audioURL)
            item.recordingID = recordingID
            item.status = .failed
            item.cloudJobID = "whole-job"
            let batch = TranscriptionBatch(name: "Retry selected audio", isProcessingClosed: true,
                recordingIDs: [recordingID], workItems: [item])
            let transcriber = BatchTestTranscriber()
            let service = FileTranscriptionBatchService(
                preparer: BatchTestPreparer(), transcriber: transcriber,
                recordingStore: BatchTestRecordingStore(existingRecordingID: recordingID,
                    audioFileURL: audioURL, savedRecording: recording),
                remoteExtractor: BatchTestRemoteExtractor(),
                chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
                batchPersistence: BatchTestPersistence(), settingsSnapshot: { .testValue },
                playCompletionSound: {})
            service.resume(batch: batch)
            try await waitUntil { !service.isProcessing }
            XCTAssertEqual(transcriber.receivedResumeJobIDs, [nil])
            XCTAssertEqual(transcriber.receivedFrameCounts.first ?? nil, 6000)
            XCTAssertEqual(transcriber.receivedDurations.first ?? nil, 0.75)
            let sentURL = try XCTUnwrap(transcriber.receivedAudioURLs.first)
            XCTAssertNotEqual(sentURL, audioURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sentURL.path))
            XCTAssertEqual(try Data(contentsOf: audioURL), originalBytes)
        }
    }

    func test_fullImportDoesNotReuseTrimmedOrPreviouslyTrimmedTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = RecordingsLibraryStorage(baseDirectory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("whole-source.wav")
        try Data([1, 2, 3, 4]).write(to: original)
        let identity = ImportedMediaIdentity(sourceURL: original)
        let remote = RemoteMediaSourceMetadata(provider: "youtube", mediaID: "trim-test",
            canonicalURL: URL(string: "https://youtube.com/watch?v=trim-test")!, title: "Whole", channelName: nil)
        let id = try XCTUnwrap(storage.saveRecording(audioData: Data([1, 2, 3, 4]), type: .fileTranscription,
            duration: 100, transcriptionText: "Whole transcript", sourceFileName: identity.fileName,
            sourceFileSizeBytes: identity.fileSizeBytes, remoteSource: remote, forceSave: true))
        let store = LiveFileTranscriptionBatchRecordingStore(storage: storage)
        XCTAssertNotNil(store.completedDuplicate(sourceIdentity: identity))
        XCTAssertNotNil(store.completedDuplicate(remoteProvider: remote.provider, mediaID: remote.mediaID))
        let selection = AudioTrimRange(startSeconds: 10, endSeconds: 40)
        XCTAssertTrue(storage.updateTrimRange(id: id, range: selection))
        XCTAssertNil(store.completedDuplicate(sourceIdentity: identity))
        XCTAssertNil(store.completedDuplicate(remoteProvider: remote.provider, mediaID: remote.mediaID))
        XCTAssertNil(store.completedDuplicate(remoteMetadata: remote, durationSeconds: 100))
        storage.completeTranscription(id: id, status: .transcribed, text: "Selected transcript", segments: nil, kind: .local)
        XCTAssertTrue(storage.updateTrimRange(id: id, range: nil))
        XCTAssertNil(store.completedDuplicate(sourceIdentity: identity))
        XCTAssertNil(store.completedDuplicate(remoteProvider: remote.provider, mediaID: remote.mediaID))
        XCTAssertNil(store.completedDuplicate(remoteMetadata: remote, durationSeconds: 100))
    }

    func test_resumedLocalBatchMarksTranscriptAsLocal() async throws {
        let recordingID = UUID()
        var item = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/source.m4a"))
        item.recordingID = recordingID
        item.status = .failed
        let batch = TranscriptionBatch(
            name: "Local retry",
            isProcessingClosed: true,
            recordingIDs: [recordingID],
            workItems: [item]
        )
        let store = BatchTestRecordingStore(
            existingRecordingID: recordingID,
            audioFileURL: URL(fileURLWithPath: "/tmp/saved.m4a")
        )
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: store,
            batchPersistence: BatchTestPersistence(),
            settingsSnapshot: { .localTestValue },
            playCompletionSound: {}
        )

        service.resume(batch: batch)
        try await waitUntil { !service.isProcessing }

        XCTAssertEqual(store.completedProvenance?.provider, "local")
    }

    func test_remoteDuplicateWithMissingCaptionsRetrievesOnlyCaptionArtifact() async throws {
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")
        let caption = TranscriptArtifact(
            text: "New captions",
            languageCode: "en",
            provenance: .youtubeAuthored
        )
        let recordingID = UUID()
        let extractor = BatchTestRemoteExtractor(caption: caption)
        let transcriber = BatchTestTranscriber()
        let store = BatchTestRecordingStore(
            remoteDuplicate: BatchTranscriptionDuplicate(
                recordingID: recordingID,
                transcriptionText: "Existing transcript",
                durationSeconds: 90
            ),
            matchingRemoteMediaID: source.mediaID
        )
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: store,
            remoteExtractor: extractor,
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.beginBatch(remoteSources: [source])
        try await waitUntil { !service.isProcessing && service.completedCount == 1 }

        XCTAssertTrue(transcriber.transcribedFileNames.isEmpty)
        XCTAssertEqual(extractor.downloadCallCount, 0)
        XCTAssertEqual(service.items.first?.transcriptionText, "Existing transcript")
        XCTAssertEqual(service.items.first?.sourceCaptionArtifacts, [caption])
        XCTAssertEqual(store.updatedCaptionArtifacts, [caption])
    }

    func test_captionOnlyDuplicateWithoutStoredAudioIsReacquired() async throws {
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")
        let caption = TranscriptArtifact(
            text: "Existing captions",
            languageCode: "en",
            provenance: .youtubeAuthored
        )
        let extractor = BatchTestRemoteExtractor()
        let store = BatchTestRecordingStore(
            remoteDuplicate: BatchTranscriptionDuplicate(
                recordingID: UUID(),
                transcriptionText: nil,
                durationSeconds: 90,
                sourceCaptionArtifacts: [caption]
            ),
            matchingRemoteMediaID: source.mediaID
        )
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: store,
            remoteExtractor: extractor,
            chromeProfile: { ChromeProfile(id: "Default", name: "Roman") },
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.beginBatch(remoteSources: [source])
        try await waitUntil { !service.isProcessing && service.completedCount == 1 }

        XCTAssertEqual(extractor.downloadCallCount, 1)
        XCTAssertNotNil(service.items.first?.transcriptionText)
    }

    func test_cloudBatchProcessesUpToThreeFilesConcurrentlyAndCompletesOnce() async throws {
        let preparer = BatchTestPreparer()
        let transcriber = BatchTestTranscriber()
        let store = BatchTestRecordingStore()
        var completionSoundCount = 0
        let service = FileTranscriptionBatchService(
            preparer: preparer,
            transcriber: transcriber,
            recordingStore: store,
            settingsSnapshot: { .testValue },
            playCompletionSound: { completionSoundCount += 1 }
        )

        service.add(urls: [
            URL(fileURLWithPath: "/tmp/first.mov"),
            URL(fileURLWithPath: "/tmp/second.mp4"),
            URL(fileURLWithPath: "/tmp/third.mp4"),
            URL(fileURLWithPath: "/tmp/fourth.mp4")
        ])
        service.startIfNeeded()
        try await waitUntil { !service.isProcessing && service.finishedCount == 4 }

        XCTAssertEqual(service.items.map(\.status), [.completed, .completed, .completed, .completed])
        XCTAssertEqual(transcriber.maximumConcurrentCount, 3)
        XCTAssertEqual(
            Set(transcriber.transcribedFileNames),
            Set(["first.m4a", "second.m4a", "third.m4a", "fourth.m4a"])
        )
        XCTAssertEqual(completionSoundCount, 1)
    }

    func test_localBatchProcessesOneFileAtATime() async throws {
        let transcriber = BatchTestTranscriber(delay: .milliseconds(80))
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: BatchTestRecordingStore(),
            settingsSnapshot: { .localTestValue },
            playCompletionSound: {}
        )

        service.add(urls: [
            URL(fileURLWithPath: "/tmp/first.mov"),
            URL(fileURLWithPath: "/tmp/second.mp4")
        ])
        service.startIfNeeded()
        try await waitUntil { !service.isProcessing && service.finishedCount == 2 }

        XCTAssertEqual(transcriber.maximumConcurrentCount, 1)
    }

    func test_add_reusesCompletedImportedRecordingAsDuplicate() throws {
        let recordingID = UUID()
        let preparer = BatchTestPreparer()
        let transcriber = BatchTestTranscriber()
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("already-done-\(UUID().uuidString).mov")
        try Data("source video".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let store = BatchTestRecordingStore(
            duplicate: BatchTranscriptionDuplicate(
                recordingID: recordingID,
                transcriptionText: "Existing transcript",
                durationSeconds: 125
            ),
            matchingSourceIdentity: ImportedMediaIdentity(sourceURL: sourceURL)
        )
        let service = FileTranscriptionBatchService(
            preparer: preparer,
            transcriber: transcriber,
            recordingStore: store,
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.beginBatch(urls: [sourceURL])

        XCTAssertEqual(service.items.first?.status, .duplicate)
        XCTAssertEqual(service.items.first?.recordingID, recordingID)
        XCTAssertEqual(service.items.first?.transcriptionText, "Existing transcript")
        XCTAssertEqual(service.items.first?.durationSeconds, 125)
        XCTAssertTrue(preparer.preparedSourceNames.isEmpty)
        XCTAssertTrue(transcriber.transcribedFileNames.isEmpty)
        XCTAssertFalse(service.isProcessing)
    }

    func test_add_doesNotReuseSameNameWithDifferentSourceSize() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DidunyDuplicateTests-\(UUID().uuidString)")
        let firstURL = root.appendingPathComponent("first").appendingPathComponent("shared.mov")
        let secondURL = root.appendingPathComponent("second").appendingPathComponent("shared.mov")
        try FileManager.default.createDirectory(
            at: firstURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("first".utf8).write(to: firstURL)
        try Data("different-size".utf8).write(to: secondURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BatchTestRecordingStore(
            duplicate: BatchTranscriptionDuplicate(
                recordingID: UUID(),
                transcriptionText: "Existing transcript",
                durationSeconds: 125
            ),
            matchingSourceIdentity: ImportedMediaIdentity(sourceURL: firstURL)
        )
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: BatchTestTranscriber(),
            recordingStore: store,
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.add(urls: [firstURL, secondURL])

        XCTAssertEqual(service.items.map(\.status), [.duplicate, .queued])
    }

    func test_failedFileDoesNotStopRemainingBatch() async throws {
        let preparer = BatchTestPreparer(failingSourceNames: ["broken.mov"])
        let transcriber = BatchTestTranscriber()
        let service = FileTranscriptionBatchService(
            preparer: preparer,
            transcriber: transcriber,
            recordingStore: BatchTestRecordingStore(),
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.add(urls: [
            URL(fileURLWithPath: "/tmp/broken.mov"),
            URL(fileURLWithPath: "/tmp/valid.mov")
        ])
        service.startIfNeeded()
        try await waitUntil { !service.isProcessing && service.finishedCount == 2 }

        XCTAssertEqual(service.items[0].status, .failed)
        XCTAssertEqual(service.items[1].status, .completed)
        XCTAssertEqual(service.failedCount, 1)
        XCTAssertEqual(service.completedCount, 1)
    }

    func test_cancelAllCancelsCurrentAndPendingItems() async throws {
        let transcriber = BatchTestTranscriber(delay: .seconds(10))
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: BatchTestRecordingStore(),
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.add(urls: [
            URL(fileURLWithPath: "/tmp/first.mov"),
            URL(fileURLWithPath: "/tmp/second.mov")
        ])
        service.startIfNeeded()
        try await waitUntil { service.items.first?.status == .uploading }
        service.cancelAll()
        try await waitUntil { !service.isProcessing }

        XCTAssertEqual(service.items.map(\.status), [.cancelled, .cancelled])
    }

    func test_preflightFailureDoesNotStartAudioPreparation() {
        let preparer = BatchTestPreparer()
        let service = FileTranscriptionBatchService(
            preparer: preparer,
            transcriber: BatchTestTranscriber(preflightError: "Download a model first."),
            recordingStore: BatchTestRecordingStore(),
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.add(urls: [URL(fileURLWithPath: "/tmp/first.mov")])
        service.startIfNeeded()

        XCTAssertEqual(service.batchError, "Download a model first.")
        XCTAssertFalse(service.isProcessing)
        XCTAssertTrue(preparer.preparedSourceNames.isEmpty)
        XCTAssertEqual(service.items.first?.status, .queued)
    }

    func test_addWhileProcessingAppendsToTheRunningBatch() async throws {
        let transcriber = BatchTestTranscriber(waitsForRelease: true)
        defer { transcriber.releaseAll() }
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: BatchTestRecordingStore(),
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.add(urls: [URL(fileURLWithPath: "/tmp/first.mov")])
        service.startIfNeeded()
        try await waitUntil { service.items.first?.status == .uploading }
        service.add(urls: [URL(fileURLWithPath: "/tmp/second.mov")])
        service.startIfNeeded()
        try await waitUntil { transcriber.maximumConcurrentCount == 2 }
        transcriber.releaseAll()
        try await waitUntil { !service.isProcessing && service.finishedCount == 2 }

        XCTAssertEqual(Set(transcriber.transcribedFileNames), Set(["first.m4a", "second.m4a"]))
        XCTAssertEqual(service.items.map(\.status), [.completed, .completed])
    }

    func test_addAfterProcessingAppendsWithoutClearingFinishedRows() async throws {
        let transcriber = BatchTestTranscriber()
        var completionSoundCount = 0
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: BatchTestRecordingStore(),
            settingsSnapshot: { .testValue },
            playCompletionSound: { completionSoundCount += 1 }
        )

        service.beginBatch(urls: [URL(fileURLWithPath: "/tmp/first.mov")])
        try await waitUntil { !service.isProcessing && service.completedCount == 1 }
        service.add(urls: [URL(fileURLWithPath: "/tmp/second.mov")])
        service.startIfNeeded()
        try await waitUntil { !service.isProcessing && service.completedCount == 2 }

        XCTAssertEqual(service.items.map(\.sourceURL.lastPathComponent), ["first.mov", "second.mov"])
        XCTAssertEqual(service.items.map(\.status), [.completed, .completed])
        XCTAssertEqual(completionSoundCount, 1)
    }

    func test_completedItemRemovesTemporaryPreparedAudio() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DidunyBatchTests-\(UUID().uuidString)")
        let preparer = BatchTestPreparer(outputDirectory: outputDirectory)
        let service = FileTranscriptionBatchService(
            preparer: preparer,
            transcriber: BatchTestTranscriber(),
            recordingStore: BatchTestRecordingStore(),
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.add(urls: [URL(fileURLWithPath: "/tmp/first.mov")])
        service.startIfNeeded()
        try await waitUntil { !service.isProcessing && service.finishedCount == 1 }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("first.m4a").path))
        try? FileManager.default.removeItem(at: outputDirectory)
    }

    func test_retryUsesInitialSettingsSnapshotAndPlaysSoundOnlyOnce() async throws {
        var snapshot = FileTranscriptionSettingsSnapshot.testValue
        let transcriber = BatchTestTranscriber(failureCount: 1)
        var completionSoundCount = 0
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: BatchTestRecordingStore(),
            settingsSnapshot: { snapshot },
            playCompletionSound: { completionSoundCount += 1 }
        )

        service.beginBatch(urls: [URL(fileURLWithPath: "/tmp/first.mov")])
        try await waitUntil { !service.isProcessing && service.failedCount == 1 }
        snapshot = FileTranscriptionSettingsSnapshot(
            provider: .local,
            languageHints: ["de"],
            localModelName: "changed-model"
        )

        service.retryFailed()
        try await waitUntil { !service.isProcessing && service.completedCount == 1 }

        XCTAssertEqual(transcriber.receivedSettings.map(\.provider), [.cloud, .cloud])
        XCTAssertEqual(transcriber.receivedSettings.map(\.languageHints), [[], []])
        XCTAssertEqual(completionSoundCount, 1)
    }

    func test_activeItemExposesExactServerProgressWithoutInventingAggregateProgress() async throws {
        let transcriber = BatchTestTranscriber(
            delay: .milliseconds(500),
            progressUpdates: [JobProgressUpdate(status: .processing, progressPercent: 40)]
        )
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: BatchTestRecordingStore(),
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )
        let firstURL = URL(fileURLWithPath: "/tmp/first.mov")

        service.beginBatch(urls: [firstURL, URL(fileURLWithPath: "/tmp/second.mov")])
        try await waitUntil {
            service.items.first?.progressFraction == 0.4
                && service.items.first.map { service.isActive($0.id) } == true
        }

        XCTAssertEqual(service.progress, 0, accuracy: 0.001)
        XCTAssertNotNil(service.items.first?.startedAt)
        XCTAssertNil(service.items.first?.finishedAt)

        service.cancelAll()
        try await waitUntil { !service.isProcessing }
    }

    func test_statusWithoutProgressClearsPreviousServerPercentage() async throws {
        let transcriber = BatchTestTranscriber(
            delay: .milliseconds(500),
            progressUpdates: [
                JobProgressUpdate(status: .processing, progressPercent: 40),
                JobProgressUpdate(status: .finalizing)
            ]
        )
        let service = FileTranscriptionBatchService(
            preparer: BatchTestPreparer(),
            transcriber: transcriber,
            recordingStore: BatchTestRecordingStore(),
            settingsSnapshot: { .testValue },
            playCompletionSound: {}
        )

        service.beginBatch(urls: [URL(fileURLWithPath: "/tmp/progress.mov")])
        try await waitUntil { service.items.first?.status == .finalizing }

        XCTAssertNil(service.items.first?.progressFraction)

        service.cancelAll()
        try await waitUntil { !service.isProcessing }
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for batch state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class BatchTestPreparer: FileTranscriptionBatchPreparing {
    private let failingSourceNames: Set<String>
    private let outputDirectory: URL
    private(set) var preparedSourceNames: [String] = []

    init(
        failingSourceNames: Set<String> = [],
        outputDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DidunyBatchTests-\(UUID().uuidString)")
    ) {
        self.failingSourceNames = failingSourceNames
        self.outputDirectory = outputDirectory
    }

    func prepare(sourceURL: URL) async throws -> ImportedMediaAudioPreparer.PreparedAudio {
        preparedSourceNames.append(sourceURL.lastPathComponent)
        if failingSourceNames.contains(sourceURL.lastPathComponent) {
            throw BatchTestError.preparationFailed
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("m4a")
        try Data("test audio".utf8).write(to: outputURL)
        return ImportedMediaAudioPreparer.PreparedAudio(
            fileURL: outputURL,
            durationSeconds: 12
        )
    }
}

@MainActor
private final class BatchTestRemoteExtractor: RemoteMediaExtracting {
    private var remainingAuthorizationFailures: Int
    private var remainingCaptionAuthorizationFailures: Int
    private var remainingCaptionFailures: Int
    private let caption: TranscriptArtifact?
    private let metadataDelay: Duration
    private let downloadDelay: Duration
    private(set) var metadataCallCount = 0
    private(set) var downloadCallCount = 0
    private(set) var maximumConcurrentDownloadCount = 0
    private var concurrentDownloadCount = 0

    init(
        metadataAuthorizationFailureCount: Int = 0,
        captionAuthorizationFailureCount: Int = 0,
        caption: TranscriptArtifact? = nil,
        captionFailureCount: Int = 0,
        metadataDelay: Duration = .zero,
        downloadDelay: Duration = .zero
    ) {
        remainingAuthorizationFailures = metadataAuthorizationFailureCount
        remainingCaptionAuthorizationFailures = captionAuthorizationFailureCount
        remainingCaptionFailures = captionFailureCount
        self.caption = caption
        self.metadataDelay = metadataDelay
        self.downloadDelay = downloadDelay
    }

    func metadata(
        for source: YouTubeRemoteMediaSource,
        session _: BrowserSession
    ) async throws -> RemoteMediaMetadata {
        metadataCallCount += 1
        if metadataDelay > .zero {
            try await Task.sleep(for: metadataDelay)
        }
        if remainingAuthorizationFailures > 0 {
            remainingAuthorizationFailures -= 1
            throw RemoteMediaExtractorError.authorizationRequired
        }
        return RemoteMediaMetadata(
            source: RemoteMediaSourceMetadata(
                provider: YouTubeRemoteMediaSource.provider,
                mediaID: source.mediaID,
                canonicalURL: source.canonicalURL,
                title: "Video \(source.mediaID)",
                channelName: "Channel"
            ),
            durationSeconds: 60,
            audioFormatID: "audio",
            estimatedAudioBytes: 1024,
            preferredCaption: caption.map {
                RemoteCaptionTrack(
                    languageCode: $0.languageCode,
                    displayName: $0.languageCode,
                    kind: $0.provenance == .youtubeAuthored ? .authored : .automatic
                )
            }
        )
    }

    func retrieveCaption(
        for _: YouTubeRemoteMediaSource,
        metadata _: RemoteMediaMetadata,
        session _: BrowserSession
    ) async throws -> TranscriptArtifact? {
        if remainingCaptionAuthorizationFailures > 0 {
            remainingCaptionAuthorizationFailures -= 1
            throw RemoteMediaExtractorError.authorizationRequired
        }
        if remainingCaptionFailures > 0 {
            remainingCaptionFailures -= 1
            throw BatchTestError.captionFailed
        }
        return caption
    }

    func downloadAudio(
        for source: YouTubeRemoteMediaSource,
        metadata _: RemoteMediaMetadata,
        session _: BrowserSession,
        onProgress: @escaping @Sendable (RemoteDownloadProgress) -> Void
    ) async throws -> RemoteDownloadedAudio {
        downloadCallCount += 1
        concurrentDownloadCount += 1
        maximumConcurrentDownloadCount = max(
            maximumConcurrentDownloadCount,
            concurrentDownloadCount
        )
        defer { concurrentDownloadCount -= 1 }
        if downloadDelay > .zero {
            try await Task.sleep(for: downloadDelay)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DidunyRemoteBatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(source.mediaID).m4a")
        try Data("remote audio".utf8).write(to: fileURL)
        onProgress(RemoteDownloadProgress(downloadedBytes: 12, totalBytes: 12))
        return RemoteDownloadedAudio(fileURL: fileURL, temporaryDirectory: directory)
    }
}

@MainActor
private final class BatchTestTranscriber: FileTranscriptionBatchTranscribing {
    private(set) var transcribedFileNames: [String] = []
    private(set) var receivedSettings: [FileTranscriptionSettingsSnapshot] = []
    private(set) var receivedAudioURLs: [URL] = []
    private(set) var receivedDurations: [TimeInterval?] = []
    private(set) var receivedFrameCounts: [AVAudioFramePosition?] = []
    private(set) var maximumConcurrentCount = 0
    private(set) var receivedResumeJobIDs: [String?] = []
    private var concurrentCount = 0
    private var remainingFailures: Int
    private let delay: Duration
    private let preflightErrorMessage: String?
    private let progressUpdates: [JobProgressUpdate]
    private let waitsForRelease: Bool
    private let transcript: GeneratedTranscript?
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        delay: Duration = .milliseconds(20),
        preflightError: String? = nil,
        failureCount: Int = 0,
        progressUpdates: [JobProgressUpdate] = [],
        waitsForRelease: Bool = false,
        transcript: GeneratedTranscript? = nil
    ) {
        self.delay = delay
        preflightErrorMessage = preflightError
        remainingFailures = failureCount
        self.progressUpdates = progressUpdates
        self.waitsForRelease = waitsForRelease
        self.transcript = transcript
    }

    func preflightError(for _: FileTranscriptionSettingsSnapshot) -> String? {
        preflightErrorMessage
    }

    func transcribe(
        audioFileURL: URL,
        settings: FileTranscriptionSettingsSnapshot,
        source _: String,
        sourceDurationSeconds: TimeInterval?,
        resumeJobID: String?,
        onJobSubmitted: @escaping (String) -> Void,
        onUpdate: @escaping (JobProgressUpdate) -> Void
    ) async throws -> GeneratedTranscript {
        receivedAudioURLs.append(audioFileURL)
        receivedDurations.append(sourceDurationSeconds)
        receivedFrameCounts.append((try? AVAudioFile(forReading: audioFileURL))?.length)
        receivedResumeJobIDs.append(resumeJobID)
        if resumeJobID == nil { onJobSubmitted("test-job") }
        transcribedFileNames.append(audioFileURL.lastPathComponent)
        receivedSettings.append(settings)
        concurrentCount += 1
        maximumConcurrentCount = max(maximumConcurrentCount, concurrentCount)
        defer { concurrentCount -= 1 }
        for update in progressUpdates {
            onUpdate(update)
            try await Task.sleep(for: .milliseconds(10))
        }
        if waitsForRelease {
            await withCheckedContinuation { releaseContinuations.append($0) }
        } else {
            try await Task.sleep(for: delay)
        }
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw BatchTestError.transcriptionFailed
        }
        return transcript ?? GeneratedTranscript(
            text: "Transcript for \(audioFileURL.lastPathComponent)"
        )
    }

    func releaseAll() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
private final class BatchTestRecordingStore: FileTranscriptionBatchRecordingStoring {
    private let savedRecording: Recording?
    private let duplicate: BatchTranscriptionDuplicate?
    private let matchingSourceIdentity: ImportedMediaIdentity?
    private let remoteDuplicate: BatchTranscriptionDuplicate?
    private let matchingRemoteMediaID: String?
    private let storesRemoteAudio: Bool
    private var storedAudioURLs: [UUID: URL] = [:]
    private(set) var updatedCaptionArtifacts: [TranscriptArtifact] = []
    private(set) var completedTranscript: GeneratedTranscript?
    private(set) var completedProvenance: GeneratedTranscriptProvenance?

    init(
        duplicate: BatchTranscriptionDuplicate? = nil,
        matchingSourceIdentity: ImportedMediaIdentity? = nil,
        remoteDuplicate: BatchTranscriptionDuplicate? = nil,
        matchingRemoteMediaID: String? = nil,
        storesRemoteAudio: Bool = false,
        existingRecordingID: UUID? = nil,
        audioFileURL: URL? = nil,
        savedRecording: Recording? = nil
    ) {
        self.savedRecording = savedRecording
        self.duplicate = duplicate
        self.matchingSourceIdentity = matchingSourceIdentity
        self.remoteDuplicate = remoteDuplicate
        self.matchingRemoteMediaID = matchingRemoteMediaID
        self.storesRemoteAudio = storesRemoteAudio
        if let existingRecordingID, let audioFileURL {
            storedAudioURLs[existingRecordingID] = audioFileURL
        }
    }

    func completedDuplicate(sourceIdentity: ImportedMediaIdentity) -> BatchTranscriptionDuplicate? {
        if let matchingSourceIdentity, matchingSourceIdentity != sourceIdentity {
            return nil
        }
        return duplicate
    }

    func completedDuplicate(remoteProvider _: String, mediaID: String) -> BatchTranscriptionDuplicate? {
        guard matchingRemoteMediaID == nil || matchingRemoteMediaID == mediaID else { return nil }
        return remoteDuplicate
    }

    func savePreparedAudio(
        at _: URL,
        durationSeconds _: TimeInterval,
        sourceIdentity _: ImportedMediaIdentity
    ) -> UUID? {
        nil
    }

    func savePreparedAudio(
        at audioURL: URL,
        durationSeconds _: TimeInterval,
        remoteMetadata _: RemoteMediaSourceMetadata,
        sourceCaptionArtifacts _: [TranscriptArtifact]
    ) -> UUID? {
        guard storesRemoteAudio else { return nil }
        let recordingID = UUID()
        let storedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DidunyStoredRemote-\(recordingID.uuidString).m4a")
        try? FileManager.default.copyItem(at: audioURL, to: storedURL)
        storedAudioURLs[recordingID] = storedURL
        return recordingID
    }

    func audioFileURL(recordingID: UUID) -> URL? {
        storedAudioURLs[recordingID]
    }

    func storedRecording(recordingID: UUID) -> Recording? {
        savedRecording?.id == recordingID ? savedRecording : nil
    }

    func updateSourceCaptionArtifacts(recordingID _: UUID, artifacts: [TranscriptArtifact]) {
        updatedCaptionArtifacts = artifacts
    }

    func markProcessing(recordingID _: UUID) {}
    func markCompleted(
        recordingID _: UUID,
        transcript: GeneratedTranscript,
        provenance: GeneratedTranscriptProvenance?
    ) {
        completedTranscript = transcript
        completedProvenance = provenance
    }

    func markFailed(recordingID _: UUID, error _: String) {}
    func markUnprocessed(recordingID _: UUID) {}
}

@MainActor
private final class BatchTestPersistence: FileTranscriptionBatchPersisting {
    let batchID = UUID()
    private(set) var createdName: String?
    private(set) var createdDescription: String?
    private(set) var recordingIDs: [UUID] = []
    private(set) var didClose = false
    private(set) var didReopen = false
    private(set) var createCount = 0

    func createBatch(
        name: String,
        description: String,
        recordingIDs: [UUID]
    ) throws -> UUID {
        createCount += 1
        createdName = name
        createdDescription = description
        self.recordingIDs = recordingIDs
        return batchID
    }

    func addRecordingIDs(_ recordingIDs: [UUID], to _: UUID) throws {
        for id in recordingIDs where !self.recordingIDs.contains(id) {
            self.recordingIDs.append(id)
        }
    }

    func replaceRecordingIDs(_ recordingIDs: [UUID], in _: UUID) throws {
        self.recordingIDs = recordingIDs
    }

    func replaceWorkItems(_: [BatchTranscriptionItem], in _: UUID) throws {}

    func reopenBatch(_: UUID) throws {
        didReopen = true
    }

    func closeBatch(_: UUID) throws {
        didClose = true
    }
}

private enum BatchTestError: Error {
    case preparationFailed
    case transcriptionFailed
    case captionFailed
}

private extension FileTranscriptionSettingsSnapshot {
    static let testValue = FileTranscriptionSettingsSnapshot(
        provider: .cloud,
        languageHints: [],
        localModelName: ""
    )

    static let localTestValue = FileTranscriptionSettingsSnapshot(
        provider: .local,
        languageHints: [],
        localModelName: "test-model"
    )
}
