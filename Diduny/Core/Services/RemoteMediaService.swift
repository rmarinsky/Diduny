import AppKit
import Foundation
import OSLog

struct RemoteMediaSourceMetadata: Codable, Equatable, Hashable {
    let provider: String
    let mediaID: String
    let canonicalURL: URL
    let title: String
    let channelName: String?
    let description: String?

    init(
        provider: String,
        mediaID: String,
        canonicalURL: URL,
        title: String,
        channelName: String?,
        description: String? = nil
    ) {
        self.provider = provider
        self.mediaID = mediaID
        self.canonicalURL = canonicalURL
        self.title = title
        self.channelName = channelName
        self.description = description
    }
}

struct TranscriptArtifact: Codable, Equatable {
    enum Provenance: String, Codable {
        case youtubeAuthored
        case youtubeAutomatic
    }

    let text: String
    let languageCode: String
    let provenance: Provenance
}

struct GeneratedTranscriptProvenance: Codable, Equatable {
    let provider: String
}

enum RemoteRecordingDuplicateMatcher {
    static func matches(
        _ recording: Recording,
        metadata: RemoteMediaSourceMetadata,
        durationSeconds: TimeInterval
    ) -> Bool {
        guard recording.type == .fileTranscription,
              !(recording.transcriptionText?.isEmpty ?? true)
              || !(recording.sourceCaptionArtifacts?.isEmpty ?? true)
        else { return false }

        if let remote = recording.remoteSource {
            return remote.provider == metadata.provider && remote.mediaID == metadata.mediaID
        }

        guard let sourceFileName = recording.sourceFileName else { return false }
        return normalizedTitle(sourceFileName) == normalizedTitle(metadata.title)
            && abs(recording.durationSeconds - durationSeconds) <= 2
    }

    private static func normalizedTitle(_ value: String) -> String {
        let withoutExtension = (value as NSString).deletingPathExtension
        return withoutExtension
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct YouTubeRemoteMediaSource: Codable, Equatable, Hashable {
    static let provider = "youtube"

    let mediaID: String
    let canonicalURL: URL

    struct BatchValidation: Equatable {
        let sources: [YouTubeRemoteMediaSource]
        let duplicateCount: Int
        let invalidValues: [String]
    }

    enum ValidationError: LocalizedError, Equatable {
        case malformedURL
        case unsupportedProvider
        case playlist
        case missingVideoID

        var errorDescription: String? {
            switch self {
            case .malformedURL:
                String(localized: "Enter a valid HTTPS YouTube URL.")
            case .unsupportedProvider:
                String(localized: "Only YouTube URLs are supported.")
            case .playlist:
                String(localized: "YouTube playlists are not supported. Add individual video URLs instead.")
            case .missingVideoID:
                String(localized: "This YouTube URL does not identify a supported video.")
            }
        }
    }

    static func normalize(_ rawValue: String) throws -> Self {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased()
        else {
            throw ValidationError.malformedURL
        }

        let pathComponents = components.path.split(separator: "/").map(String.init)
        let mediaID: String?
        switch host {
        case "youtu.be", "www.youtu.be":
            mediaID = pathComponents.first
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com":
            if pathComponents.first == "playlist" {
                throw ValidationError.playlist
            }
            if pathComponents.first == "watch" || pathComponents.isEmpty {
                mediaID = components.queryItems?.first(where: { $0.name == "v" })?.value
            } else if ["shorts", "embed", "live"].contains(pathComponents.first) {
                mediaID = pathComponents.dropFirst().first
            } else {
                mediaID = nil
            }
        default:
            throw ValidationError.unsupportedProvider
        }

        guard let mediaID, isValidVideoID(mediaID) else {
            throw ValidationError.missingVideoID
        }
        guard let canonicalURL = URL(string: "https://www.youtube.com/watch?v=\(mediaID)") else {
            throw ValidationError.malformedURL
        }
        return Self(mediaID: mediaID, canonicalURL: canonicalURL)
    }

    static func normalizeBatch(_ rawValue: String) throws -> [Self] {
        let values = rawValue
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        var seen = Set<String>()
        return try values.compactMap { value in
            let source = try normalize(value)
            return seen.insert(source.mediaID).inserted ? source : nil
        }
    }

    static func validateBatch(
        _ rawValue: String,
        excludingMediaIDs: Set<String> = []
    ) -> BatchValidation {
        let values = rawValue
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var sources: [Self] = []
        var seen = excludingMediaIDs
        var duplicateCount = 0
        var invalidValues: [String] = []

        for value in values {
            do {
                let source = try normalize(value)
                if seen.insert(source.mediaID).inserted {
                    sources.append(source)
                } else {
                    duplicateCount += 1
                }
            } catch {
                invalidValues.append(value)
            }
        }
        return BatchValidation(
            sources: sources,
            duplicateCount: duplicateCount,
            invalidValues: invalidValues
        )
    }

    private static func isValidVideoID(_ value: String) -> Bool {
        value.count == 11
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
            }
    }
}

struct RemoteCaptionTrack: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case authored
        case automatic
    }

    let languageCode: String
    let displayName: String
    let kind: Kind

    static func preferred(
        authored: [Self],
        automatic: [Self],
        originalLanguageCode: String?
    ) -> Self? {
        preferredTrack(in: authored, originalLanguageCode: originalLanguageCode)
            ?? preferredTrack(in: automatic, originalLanguageCode: originalLanguageCode)
    }

    private static func preferredTrack(
        in tracks: [Self],
        originalLanguageCode: String?
    ) -> Self? {
        guard !tracks.isEmpty else { return nil }
        guard let originalLanguageCode = normalizedLanguage(originalLanguageCode) else {
            return nil
        }
        return tracks.first(where: {
            let trackLanguage = normalizedLanguage($0.languageCode)
            return trackLanguage == originalLanguageCode
                || trackLanguage?.hasPrefix(originalLanguageCode + "-") == true
        })
    }

    private static func normalizedLanguage(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased().replacingOccurrences(of: "_", with: "-")
        return normalized.isEmpty ? nil : normalized
    }
}

enum RemoteMediaExtractorError: LocalizedError, Equatable {
    case runtimeUnavailable
    case malformedMetadata
    case sourceIdentityMismatch
    case unsupportedLiveStream
    case unsupportedDRM
    case noAudioOnlyStream
    case authorizationRequired
    case browserCookiesUnavailable
    case botVerificationRequired
    case sourceUnavailable
    case extractorOutdated
    case insufficientDiskSpace
    case acquisitionFailed

    var requiresBrowserRecovery: Bool {
        self == .authorizationRequired || self == .browserCookiesUnavailable || self == .botVerificationRequired
    }

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            String(localized: "Remote media support is unavailable in this Diduny build. Update Diduny and try again.")
        case .malformedMetadata, .sourceIdentityMismatch:
            String(localized: "Diduny could not verify this YouTube video.")
        case .unsupportedLiveStream:
            String(localized: "Active YouTube livestreams are not supported.")
        case .unsupportedDRM:
            String(localized: "This rental or DRM-protected video is not supported.")
        case .noAudioOnlyStream:
            String(localized: "Unsupported — no audio-only stream available.")
        case .authorizationRequired:
            String(localized: "YouTube requires sign-in. Open the video in the selected browser profile, sign in, then check access.")
        case .browserCookiesUnavailable:
            String(localized: "Diduny cannot read this browser profile’s cookies. Choose another profile, or close the browser and check access again.")
        case .botVerificationRequired:
            String(localized: "YouTube requires a verification check. Open the video in the selected browser profile, complete the check, then check access again.")
        case .sourceUnavailable:
            String(localized: "This video is private, removed, or unavailable in your region. Open YouTube to check whether the selected profile can play it.")
        case .extractorOutdated:
            String(localized: "YouTube compatibility requires a Diduny update.")
        case .insufficientDiskSpace:
            String(localized: "There is not enough free disk space to prepare this audio.")
        case .acquisitionFailed:
            String(localized: "Diduny could not retrieve audio from this video.")
        }
    }
}

struct RemoteMediaMetadata: Codable, Equatable {
    let source: RemoteMediaSourceMetadata
    let durationSeconds: TimeInterval
    let audioFormatID: String
    let estimatedAudioBytes: Int64?
    let preferredCaption: RemoteCaptionTrack?

    static func decodeYTDLPJSON(
        _ data: Data,
        expectedSource: YouTubeRemoteMediaSource
    ) throws -> Self {
        let payload: YTDLPPayload
        do {
            payload = try JSONDecoder().decode(YTDLPPayload.self, from: data)
        } catch {
            throw RemoteMediaExtractorError.malformedMetadata
        }

        guard payload.id == expectedSource.mediaID else {
            throw RemoteMediaExtractorError.sourceIdentityMismatch
        }
        guard payload.isLive != true else {
            throw RemoteMediaExtractorError.unsupportedLiveStream
        }
        guard payload.availability != "premium_only",
              payload.availability != "subscriber_only",
              payload.formats.contains(where: { $0.hasDRM == true }) == false
        else {
            throw RemoteMediaExtractorError.unsupportedDRM
        }
        guard payload.duration.isFinite, payload.duration > 0 else {
            throw RemoteMediaExtractorError.malformedMetadata
        }

        let compatibleAudio = payload.formats
            .filter {
                $0.audioCodec != nil
                    && $0.audioCodec != "none"
                    && ($0.videoCodec == nil || $0.videoCodec == "none")
                    && ["m4a", "mp4", "mp3"].contains($0.fileExtension.lowercased())
                    && $0.hasDRM != true
            }
            .max {
                let left = $0.audioBitrate ?? $0.totalBitrate ?? 0
                let right = $1.audioBitrate ?? $1.totalBitrate ?? 0
                return left < right
            }
        guard let compatibleAudio else {
            throw RemoteMediaExtractorError.noAudioOnlyStream
        }

        let authored = captionTracks(from: payload.subtitles, kind: .authored)
        let automatic = captionTracks(from: payload.automaticCaptions, kind: .automatic)
        let caption = RemoteCaptionTrack.preferred(
            authored: authored,
            automatic: automatic,
            originalLanguageCode: payload.originalLanguage
        )
        let estimatedBytes = compatibleAudio.fileSize ?? compatibleAudio.approximateFileSize

        return Self(
            source: RemoteMediaSourceMetadata(
                provider: YouTubeRemoteMediaSource.provider,
                mediaID: payload.id,
                canonicalURL: expectedSource.canonicalURL,
                title: payload.title,
                channelName: payload.channelName,
                description: payload.description
            ),
            durationSeconds: payload.duration,
            audioFormatID: compatibleAudio.id,
            estimatedAudioBytes: estimatedBytes,
            preferredCaption: caption
        )
    }

    private static func captionTracks(
        from groups: [String: [YTDLPCaption]]?,
        kind: RemoteCaptionTrack.Kind
    ) -> [RemoteCaptionTrack] {
        guard let groups else { return [] }
        return groups.keys.sorted().compactMap { languageCode in
            guard languageCode != "live_chat",
                  let entry = groups[languageCode]?.first(where: { $0.fileExtension == "vtt" })
                  ?? groups[languageCode]?.first
            else { return nil }
            return RemoteCaptionTrack(
                languageCode: languageCode,
                displayName: entry.name ?? languageCode,
                kind: kind
            )
        }
    }
}

private struct YTDLPPayload: Decodable {
    let id: String
    let title: String
    let channelName: String?
    let description: String?
    let duration: TimeInterval
    let originalLanguage: String?
    let isLive: Bool?
    let availability: String?
    let formats: [YTDLPFormat]
    let subtitles: [String: [YTDLPCaption]]?
    let automaticCaptions: [String: [YTDLPCaption]]?

    enum CodingKeys: String, CodingKey {
        case id, title, description, duration, availability, formats, subtitles
        case channelName = "uploader"
        case originalLanguage = "original_language"
        case isLive = "is_live"
        case automaticCaptions = "automatic_captions"
    }
}

private struct YTDLPFormat: Decodable {
    let id: String
    let fileExtension: String
    let audioCodec: String?
    let videoCodec: String?
    let audioBitrate: Double?
    let totalBitrate: Double?
    let fileSize: Int64?
    let approximateFileSize: Int64?
    let hasDRM: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "format_id"
        case fileExtension = "ext"
        case audioCodec = "acodec"
        case videoCodec = "vcodec"
        case audioBitrate = "abr"
        case totalBitrate = "tbr"
        case fileSize = "filesize"
        case approximateFileSize = "filesize_approx"
        case hasDRM = "has_drm"
    }
}

private struct YTDLPCaption: Decodable {
    let name: String?
    let fileExtension: String?

    enum CodingKeys: String, CodingKey {
        case name
        case fileExtension = "ext"
    }
}

enum WebVTTTranscriptParser {
    static func parse(_ value: String) -> String {
        var result: [String] = []
        for rawLine in value.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed != "WEBVTT",
                  !trimmed.contains("-->"),
                  Int(trimmed) == nil,
                  !trimmed.hasPrefix("NOTE"),
                  !trimmed.hasPrefix("STYLE")
            else { continue }

            let withoutTags = trimmed.replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
            let decoded = withoutTags
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !decoded.isEmpty, result.last != decoded else { continue }
            result.append(decoded)
        }
        return result.joined(separator: "\n")
    }
}

enum BrowserKind: String, Codable, CaseIterable, Hashable {
    case brave
    case chrome
    case edge
    case firefox
    case safari
    case zen

    var displayName: String {
        switch self {
        case .brave: String(localized: "Brave")
        case .chrome: String(localized: "Google Chrome")
        case .edge: String(localized: "Microsoft Edge")
        case .firefox: String(localized: "Firefox")
        case .safari: String(localized: "Safari")
        case .zen: String(localized: "Zen")
        }
    }

    var cookieSource: String {
        self == .zen ? BrowserKind.firefox.rawValue : rawValue
    }

    var bundleIdentifier: String {
        switch self {
        case .brave: "com.brave.Browser"
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .firefox: "org.mozilla.firefox"
        case .safari: "com.apple.Safari"
        case .zen: "app.zen-browser.zen"
        }
    }

    var applicationSupportPath: String? {
        switch self {
        case .brave: "BraveSoftware/Brave-Browser"
        case .chrome: "Google/Chrome"
        case .edge: "Microsoft Edge"
        case .firefox: "Firefox"
        case .safari: nil
        case .zen: "zen"
        }
    }
}

struct BrowserSession: Codable, Equatable, Hashable, Identifiable {
    let browser: BrowserKind
    let profileID: String?
    let profileName: String?

    var id: String {
        profileID ?? browser.rawValue
    }

    var selectionID: String {
        "\(browser.rawValue)|\(profileID ?? "")"
    }

    var name: String {
        profileName ?? browser.displayName
    }

    var displayName: String {
        profileName.map { "\(browser.displayName) — \($0)" } ?? browser.displayName
    }

    var cookieArgument: String {
        profileID.map { "\(browser.cookieSource):\($0)" } ?? browser.cookieSource
    }

    init(browser: BrowserKind, profileID: String? = nil, profileName: String? = nil) {
        self.browser = browser
        self.profileID = profileID
        self.profileName = profileName
    }

    init(id: String, name: String) {
        self.init(browser: .chrome, profileID: id, profileName: name)
    }
}

extension BrowserSession {
    func launchArguments(for url: URL) -> [String] {
        switch browser {
        case .chrome, .brave, .edge:
            return profileID.map { ["--profile-directory=\($0)", "--new-window", url.absoluteString] }
                ?? ["--new-window", url.absoluteString]
        case .firefox, .zen:
            return profileID.map { ["--no-remote", "--profile", $0, "--new-tab", url.absoluteString] }
                ?? ["--new-tab", url.absoluteString]
        case .safari:
            return []
        }
    }

    @MainActor
    func openYouTube(_ source: YouTubeRemoteMediaSource) async throws {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) else {
            throw BrowserOpenError.browserUnavailable
        }
        // Firefox's remote process can ignore a requested profile. Require it to be closed
        // before launching a separate instance, rather than opening another account.
        if [.firefox, .zen].contains(browser), profileID != nil,
           !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier).isEmpty {
            throw BrowserOpenError.closeFirefoxFirst
        }
        let configuration = NSWorkspace.OpenConfiguration()
        if browser == .safari {
            _ = try await NSWorkspace.shared.open([source.canonicalURL], withApplicationAt: application, configuration: configuration)
        } else {
            configuration.arguments = launchArguments(for: source.canonicalURL)
            configuration.createsNewApplicationInstance = true
            _ = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
        }
    }
}

private enum BrowserOpenError: LocalizedError {
    case browserUnavailable
    case closeFirefoxFirst

    var errorDescription: String? {
        switch self {
        case .browserUnavailable:
            String(localized: "This browser is no longer available. Select another browser profile.")
        case .closeFirefoxFirst:
            String(localized: "Close Firefox or Zen before opening a specific profile, then try Open YouTube again.")
        }
    }
}

typealias ChromeProfile = BrowserSession

enum BrowserSessionStore {
    static var defaultUserDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    static func discoverChromium(
        browser: BrowserKind,
        in userDataDirectory: URL
    ) -> [BrowserSession] {
        let stateURL = userDataDirectory.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: [String: Any]]
        else { return [] }

        return infoCache.compactMap { id, metadata in
            let directory = userDataDirectory.appendingPathComponent(id, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return nil }
            return BrowserSession(
                browser: browser,
                profileID: id,
                profileName: metadata["name"] as? String ?? id
            )
        }
        .sorted { left, right in
            if left.id == "Default" { return true }
            if right.id == "Default" { return false }
            return left.id.localizedStandardCompare(right.id) == .orderedAscending
        }
    }

    static func discoverFirefox(
        browser: BrowserKind,
        in userDataDirectory: URL
    ) -> [BrowserSession] {
        guard let value = try? String(
            contentsOf: userDataDirectory.appendingPathComponent("profiles.ini"),
            encoding: .utf8
        ) else { return [] }

        var sections: [String: [String: String]] = [:]
        var currentSection: String?
        for rawLine in value.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]") {
                let section = String(line.dropFirst().dropLast())
                currentSection = section.hasPrefix("Profile") ? section : nil
            } else if let currentSection, let separator = line.firstIndex(of: "=") {
                sections[currentSection, default: [:]][String(line[..<separator])] =
                    String(line[line.index(after: separator)...])
            }
        }

        return sections.keys.sorted().compactMap { section in
            guard let values = sections[section],
                  let path = values["Path"]
            else { return nil }
            let profileURL = values["IsRelative"] == "1"
                ? userDataDirectory.appendingPathComponent(path, isDirectory: true)
                : URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: profileURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else { return nil }
            return BrowserSession(
                browser: browser,
                profileID: profileURL.path,
                profileName: values["Name"] ?? profileURL.lastPathComponent
            )
        }
    }

    @MainActor
    static func discover() -> [BrowserSession] {
        let installed = Set(BrowserKind.allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
        })
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return discover(
            installedBrowsers: installed,
            applicationSupportDirectory: applicationSupport
        )
    }

    static func discover(
        installedBrowsers: Set<BrowserKind>,
        applicationSupportDirectory: URL
    ) -> [BrowserSession] {
        BrowserKind.allCases.flatMap { browser -> [BrowserSession] in
            guard installedBrowsers.contains(browser) else { return [] }
            guard let path = browser.applicationSupportPath else {
                return [BrowserSession(browser: browser)]
            }
            let directory = applicationSupportDirectory.appendingPathComponent(path, isDirectory: true)
            switch browser {
            case .firefox, .zen:
                let sessions = discoverFirefox(browser: browser, in: directory)
                return sessions.isEmpty && browser == .firefox
                    ? [BrowserSession(browser: browser)]
                    : sessions
            case .safari:
                return [BrowserSession(browser: browser)]
            default:
                let sessions = discoverChromium(browser: browser, in: directory)
                return sessions.isEmpty ? [BrowserSession(browser: browser)] : sessions
            }
        }
    }

    static func selected(
        from sessions: [BrowserSession],
        selectionID: String?,
        legacyChromeProfileID: String?
    ) -> BrowserSession? {
        if let selectionID,
           let selected = sessions.first(where: { $0.selectionID == selectionID })
        {
            return selected
        }
        if let legacyChromeProfileID,
           let selected = sessions.first(where: {
               $0.browser == .chrome && $0.profileID == legacyChromeProfileID
           })
        {
            return selected
        }
        return sessions.first
    }
}

enum ChromeProfileStore {
    static func discover(
        in userDataDirectory: URL = BrowserSessionStore.defaultUserDataDirectory
    ) -> [ChromeProfile] {
        BrowserSessionStore.discoverChromium(browser: .chrome, in: userDataDirectory)
    }
}

struct RemoteDownloadedAudio {
    let fileURL: URL
    let temporaryDirectory: URL

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

struct RemoteDownloadProgress: Equatable {
    let downloadedBytes: Int64
    let totalBytes: Int64?

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }
}

@MainActor
protocol RemoteMediaExtracting: AnyObject {
    func metadata(
        for source: YouTubeRemoteMediaSource,
        session: BrowserSession
    ) async throws -> RemoteMediaMetadata

    func retrieveCaption(
        for source: YouTubeRemoteMediaSource,
        metadata: RemoteMediaMetadata,
        session: BrowserSession
    ) async throws -> TranscriptArtifact?

    func downloadAudio(
        for source: YouTubeRemoteMediaSource,
        metadata: RemoteMediaMetadata,
        session: BrowserSession,
        onProgress: @escaping @Sendable (RemoteDownloadProgress) -> Void
    ) async throws -> RemoteDownloadedAudio
}

final class BundledRemoteMediaExtractor: RemoteMediaExtracting {
    private let ytDLPURL: URL?
    private let denoURL: URL?
    private let temporaryDirectory: URL

    init(
        ytDLPURL: URL? = Bundle.main.url(
            forResource: "yt-dlp_macos",
            withExtension: nil,
            subdirectory: "RemoteMediaRuntime"
        ),
        denoURL: URL? = Bundle.main.url(
            forResource: "deno",
            withExtension: nil,
            subdirectory: "RemoteMediaRuntime"
        ),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.ytDLPURL = ytDLPURL
        self.denoURL = denoURL
        self.temporaryDirectory = temporaryDirectory
    }

    func metadata(
        for source: YouTubeRemoteMediaSource,
        session: BrowserSession
    ) async throws -> RemoteMediaMetadata {
        let runtime = try runtime()
        let result = try await run(
            executableURL: runtime.ytDLP,
            arguments: Self.metadataArguments(
                source: source,
                session: session,
                denoURL: runtime.deno
            )
        )
        return try RemoteMediaMetadata.decodeYTDLPJSON(result.standardOutput, expectedSource: source)
    }

    func retrieveCaption(
        for source: YouTubeRemoteMediaSource,
        metadata: RemoteMediaMetadata,
        session: BrowserSession
    ) async throws -> TranscriptArtifact? {
        guard let track = metadata.preferredCaption else { return nil }
        let runtime = try runtime()
        let directory = temporaryDirectory
            .appendingPathComponent("diduny-youtube-caption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputTemplate = directory.appendingPathComponent("caption.%(ext)s").path
        var arguments = Self.commonArguments(session: session, denoURL: runtime.deno)
        arguments += [
            "--skip-download",
            track.kind == .authored ? "--write-subs" : "--write-auto-subs",
            "--sub-langs", track.languageCode,
            "--sub-format", "vtt",
            "--output", outputTemplate,
            source.canonicalURL.absoluteString
        ]
        _ = try await run(executableURL: runtime.ytDLP, arguments: arguments)

        guard let captionURL = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first(where: { $0.pathExtension.lowercased() == "vtt" }),
            let value = try? String(contentsOf: captionURL, encoding: .utf8)
        else { return nil }

        let text = WebVTTTranscriptParser.parse(value)
        guard !text.isEmpty else { return nil }
        return TranscriptArtifact(
            text: text,
            languageCode: track.languageCode,
            provenance: track.kind == .authored ? .youtubeAuthored : .youtubeAutomatic
        )
    }

    func downloadAudio(
        for source: YouTubeRemoteMediaSource,
        metadata: RemoteMediaMetadata,
        session: BrowserSession,
        onProgress: @escaping @Sendable (RemoteDownloadProgress) -> Void
    ) async throws -> RemoteDownloadedAudio {
        try ensureDiskSpace(estimatedBytes: metadata.estimatedAudioBytes)
        let runtime = try runtime()
        let directory = temporaryDirectory
            .appendingPathComponent("diduny-youtube-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            let outputTemplate = directory.appendingPathComponent("source.%(ext)s").path
            _ = try await run(
                executableURL: runtime.ytDLP,
                arguments: Self.downloadArguments(
                    source: source,
                    session: session,
                    denoURL: runtime.deno,
                    audioFormatID: metadata.audioFormatID,
                    outputTemplate: outputTemplate
                ),
                onProgress: onProgress
            )
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
            guard let audioURL = files.first(where: {
                !["json", "vtt", "part", "ytdl"].contains($0.pathExtension.lowercased())
            }) else {
                throw RemoteMediaExtractorError.acquisitionFailed
            }
            return RemoteDownloadedAudio(fileURL: audioURL, temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    nonisolated static func metadataArguments(
        source: YouTubeRemoteMediaSource,
        session: BrowserSession,
        denoURL: URL
    ) -> [String] {
        commonArguments(session: session, denoURL: denoURL) + [
            "--skip-download",
            "--dump-single-json",
            source.canonicalURL.absoluteString
        ]
    }

    nonisolated static func downloadArguments(
        source: YouTubeRemoteMediaSource,
        session: BrowserSession,
        denoURL: URL,
        audioFormatID: String,
        outputTemplate: String
    ) -> [String] {
        commonArguments(session: session, denoURL: denoURL) + [
            "--newline",
            "--progress",
            "--progress-template",
            "download:diduny-progress:%(progress.downloaded_bytes)s:%(progress.total_bytes)s:%(progress.total_bytes_estimate)s",
            "--format", audioFormatID,
            "--output", outputTemplate,
            source.canonicalURL.absoluteString
        ]
    }

    private nonisolated static func commonArguments(
        session: BrowserSession,
        denoURL: URL
    ) -> [String] {
        [
            "--no-config",
            "--no-playlist",
            "--no-warnings",
            "--js-runtimes", "deno:\(denoURL.path)",
            "--cookies-from-browser", session.cookieArgument
        ]
    }

    private func runtime() throws -> (ytDLP: URL, deno: URL) {
        guard let ytDLPURL, let denoURL,
              FileManager.default.isExecutableFile(atPath: ytDLPURL.path),
              FileManager.default.isExecutableFile(atPath: denoURL.path)
        else { throw RemoteMediaExtractorError.runtimeUnavailable }
        return (ytDLPURL, denoURL)
    }

    private func ensureDiskSpace(estimatedBytes: Int64?) throws {
        guard let available = try? temporaryDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage else { return }
        let required = max(estimatedBytes ?? 0, 100 * 1024 * 1024)
        guard available > required else {
            throw RemoteMediaExtractorError.insufficientDiskSpace
        }
    }

    private struct ProcessResult {
        let standardOutput: Data
        let standardError: Data
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        onProgress: (@Sendable (RemoteDownloadProgress) -> Void)? = nil,
        allowsPublicFallback: Bool = true
    ) async throws -> ProcessResult {
        let processTemporaryDirectory = temporaryDirectory
            .appendingPathComponent("diduny-extractor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: processTemporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: processTemporaryDirectory) }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = processTemporaryDirectory
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin",
            "TMPDIR": processTemporaryDirectory.path
        ]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withTaskCancellationHandler {
            let outputTask = Task.detached(priority: .utility) {
                Self.readAll(from: outputPipe.fileHandleForReading, onProgress: onProgress)
            }
            let errorTask = Task.detached(priority: .utility) {
                Self.readAll(from: errorPipe.fileHandleForReading, onProgress: onProgress)
            }

            let terminationStatus: Int32
            do {
                terminationStatus = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Int32, Error>) in
                    process.terminationHandler = { terminatedProcess in
                        continuation.resume(returning: terminatedProcess.terminationStatus)
                    }
                    do {
                        try process.run()
                    } catch {
                        process.terminationHandler = nil
                        try? outputPipe.fileHandleForWriting.close()
                        try? errorPipe.fileHandleForWriting.close()
                        continuation.resume(
                            throwing: RemoteMediaExtractorError.runtimeUnavailable
                        )
                    }
                }
            } catch {
                outputTask.cancel()
                errorTask.cancel()
                throw error
            }

            let output = await outputTask.value
            let error = await errorTask.value
            try Task.checkCancellation()
            guard terminationStatus == 0 else {
                if allowsPublicFallback,
                   Self.isBrowserCookieDatabaseFailure(error),
                   let publicArguments = Self.removingBrowserSession(from: arguments)
                {
                    Log.app.warning(
                        "Selected browser session cookies are unavailable; retrying public YouTube access"
                    )
                    do {
                        return try await run(
                            executableURL: executableURL,
                            arguments: publicArguments,
                            onProgress: onProgress,
                            allowsPublicFallback: false
                        )
                    } catch let fallbackError as RemoteMediaExtractorError where fallbackError.requiresBrowserRecovery {
                        throw RemoteMediaExtractorError.browserCookiesUnavailable
                    }
                }
                let failure = Self.classifyFailure(error)
                Log.app.error(
                    "Remote media extractor failed with status \(terminationStatus, privacy: .public), category \(String(describing: failure), privacy: .public)"
                )
                throw failure
            }
            return ProcessResult(standardOutput: output, standardError: error)
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private nonisolated static func isBrowserCookieDatabaseFailure(_ data: Data) -> Bool {
        let message = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        return message.contains("no such table: meta")
            || message.contains("no such table: cookies")
            || message.contains("could not copy chrome cookie database")
            || message.contains("failed to load cookies")
            || message.contains("cookie") && (message.contains("failed to decrypt")
                || message.contains("permission denied") || message.contains("operation not permitted")
                || message.contains("database is locked"))
    }

    private nonisolated static func removingBrowserSession(from arguments: [String]) -> [String]? {
        guard let optionIndex = arguments.firstIndex(of: "--cookies-from-browser"),
              arguments.indices.contains(optionIndex + 1)
        else { return nil }
        var result = arguments
        result.removeSubrange(optionIndex ... optionIndex + 1)
        return result
    }

    private nonisolated static func readAll(
        from handle: FileHandle,
        onProgress: (@Sendable (RemoteDownloadProgress) -> Void)?
    ) -> Data {
        var result = Data()
        var progressBuffer = Data()

        while !Task.isCancelled,
              let chunk = try? handle.read(upToCount: 64 * 1024),
              !chunk.isEmpty
        {
            result.append(chunk)
            guard let onProgress else { continue }
            progressBuffer.append(chunk)
            while let newlineIndex = progressBuffer.firstIndex(of: 0x0A) {
                let line = progressBuffer.prefix(upTo: newlineIndex)
                reportProgress(in: Data(line), callback: onProgress)
                progressBuffer.removeSubrange(...newlineIndex)
            }
        }

        if let onProgress, !progressBuffer.isEmpty {
            reportProgress(in: progressBuffer, callback: onProgress)
        }
        return result
    }

    private nonisolated static func reportProgress(
        in data: Data,
        callback: @Sendable (RemoteDownloadProgress) -> Void
    ) {
        guard let value = String(data: data, encoding: .utf8) else { return }
        for line in value.components(separatedBy: .newlines) where line.hasPrefix("diduny-progress:") {
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 4, let downloaded = Int64(parts[1]) else { continue }
            let total = Int64(parts[2]) ?? Int64(parts[3])
            callback(RemoteDownloadProgress(downloadedBytes: downloaded, totalBytes: total))
        }
    }

    nonisolated static func classifyFailure(_ data: Data) -> RemoteMediaExtractorError {
        let message = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        if message.contains("private video")
            || message.contains("video unavailable")
            || message.contains("not available in your country")
            || message.contains("has been removed")
        {
            return .sourceUnavailable
        }
        if isBrowserCookieDatabaseFailure(data) || message.contains("could not find") && message.contains("cookies") {
            return .browserCookiesUnavailable
        }
        if message.contains("not a bot") || message.contains("confirm you’re not") {
            return .botVerificationRequired
        }
        if message.contains("sign in") || message.contains("login required") {
            return .authorizationRequired
        }
        if message.contains("unsupported url") || message.contains("extractor") && message.contains("update") {
            return .extractorOutdated
        }
        return .acquisitionFailed
    }
}
