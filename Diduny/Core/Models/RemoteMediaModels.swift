import Foundation

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
