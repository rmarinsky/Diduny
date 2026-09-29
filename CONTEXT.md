# Diduny Transcription

The language used for bringing recorded media into Diduny and producing reusable transcripts.

## Language

**Voice Translation**:
Spoken input converted to one selected output language. Mixing languages while speaking does not reverse the output direction. Words already in the output language remain part of the result.
_Avoid_: Two-way voice dictation, automatic output-language switching

**Stop-to-Paste Latency**:
The elapsed time between the user's Stop action and the completed text appearing in the intended input field. A visible transcription preview is not a completed insertion.
_Avoid_: Time to first token, transcription preview latency

**Transcription Batch**:
A persisted snapshot of one grouped transcription run. Items may be added while the run is processing, but normal membership editing ends when processing finishes. Its name and description remain editable. Deleting a recording is an explicit exception that removes its membership and updates the batch.
_Avoid_: Project, folder, permanent collection

**Batch Member**:
A reference to any recording included in a transcription batch, including Voice, Meeting, File, YouTube, or a recording with a translation. The same recording may belong to multiple batches without being moved or copied. A batch may combine existing Library recordings with newly supplied files and URLs. Adding an existing completed recording reuses its transcript artifacts without transcribing it again; reprocessing requires an explicit Transcribe Again request.
_Avoid_: Copied recording, moved recording, automatic retranscription

**Batch Processing Status**:
A batch-level status derived from its members rather than edited by the user. It is Processing while work remains, Completed when every member succeeds, and Completed with Issues when processing finishes with at least one failed or partial result.
_Avoid_: Manual project status, progress percentage

**Processing Checkpoint**:
The latest durable successful result in a recording's multi-step workflow. Retrying resumes at the failed step and reuses valid earlier results, such as remote metadata, source captions, acquired audio, or prepared audio. Intermediate files are retained until the item succeeds or its batch is deleted.
_Avoid_: Restart batch, repeat all steps

**Batch Deletion**:
A destructive operation that deletes the transcription batch and every recording referenced by it. Recordings shared with other batches are removed from those batches as part of the same operation. The user sees an explicit confirmation with the affected recording count before deletion.
_Avoid_: Delete grouping only, preserve shared recordings

**Recording Deletion**:
Removal of a recording from the Library and every batch that references it. Completed batches update their membership and counts after the recording is deleted.
_Avoid_: Batch tombstone, immutable deleted member

**Batch Transcript Export**:
A Markdown document produced by Copy All Transcripts. Each batch member has a heading with its recording name and source type followed by its transcript; members without a completed transcript retain a labeled status placeholder.
_Avoid_: Unlabeled text concatenation, format picker

**Batch Creation Date**:
The immutable date and time when a transcription batch is created. Batch lists sort by this value with the newest batch first.
_Avoid_: Last updated date, last activity

**Default Batch Name**:
An editable generated name containing the batch creation date and time, used when the user does not provide a name.
_Avoid_: Required name, first recording name

**Translation Artifact**:
Translated text attached to a recording. It is searchable and filterable as Has Translation but is not a separate recording type in the target Library model.
_Avoid_: Translation recording, translated source

**Remote Media Source**:
A media item identified by a URL rather than a file already available on the user's Mac.
_Avoid_: URL file, web video

**Remote Source Identity**:
The provider and provider-assigned media identifier that identify one remote media item independently of URL shape or browser parameters.
_Avoid_: Raw URL, video title

**Duplicate Remote Source**:
A queued remote source that matches an existing recording by remote source identity or by normalized video title and duration. Its available transcript artifacts are reused unless the user explicitly requests another transcription.
_Avoid_: Raw URL match, filename and byte-size match

**Remote Media Extractor**:
The Diduny-supplied capability that retrieves audio-only media and source captions from a supported remote media source. It is part of the product rather than a user-installed prerequisite.
_Avoid_: External tool, optional downloader

**Authenticated YouTube Source**:
A YouTube video that Diduny can access using the user's authenticated browser session and that is supported by the URL transcription workflow.
_Avoid_: Experimental YouTube import, Google-authenticated URL

**Supported YouTube Video**:
An individual, non-live YouTube video the user can currently watch and from which Diduny can acquire an audio-only stream. This may include public, unlisted, private, age-restricted videos, and Shorts; active livestreams, playlists, rentals, DRM-protected media, and videos without an accessible audio-only stream are outside this term.
_Avoid_: Any YouTube link, YouTube playlist

**Audio-Only Acquisition**:
Retrieval of a remote source's audio stream without downloading its video bytes. A YouTube source that cannot satisfy this boundary is unsupported rather than downloaded as full media.
_Avoid_: Video download, full-media fallback

**Browser Session**:
Authentication state owned and persisted by the user's selected supported browser profile. Diduny may use it to access a remote media source but does not copy or retain its credentials.
_Avoid_: Diduny Google session, stored Google authorization, copied browser credentials

**Selected Browser Session**:
The browser profile chosen for authenticated remote-media access and remembered by identifier until the user changes it. Its authentication state remains owned by that browser.
_Avoid_: Default browser assumption, per-video credential copy

**Authorization Pause**:
A recoverable batch state entered before remote media is downloaded when the selected browser session cannot authorize access. Queued items remain unchanged until the user restores the browser session and explicitly retries authorization.
_Avoid_: Authentication failure, cancelled batch

**Source Captions**:
Caption tracks supplied with a remote media source, whether authored or automatically generated by its provider. They remain distinct from Diduny's generated transcript.
_Avoid_: Diduny transcript, transcription result

**Original-Language Captions**:
The source-caption track in the video's original spoken language. Diduny prefers an authored track, falls back to an automatic track, and does not add translated tracks for the configured transcription language.
_Avoid_: All captions, translated captions

**Automatic Captions**:
Provider-generated source captions used only when authored original-language captions are unavailable. Their automatic origin remains visible wherever the artifact is presented or exported.
_Avoid_: Authored captions, generated transcript

**Generated Transcript**:
Text produced by transcribing the media audio through Diduny's configured transcription provider. It is created independently even when source captions exist.
_Avoid_: Source captions, YouTube subtitles

**Transcript Artifact**:
A persisted text result attached to a recording with explicit provenance. A recording may contain one primary generated transcript and separate source-caption artifacts.
_Avoid_: Merged transcript, unlabeled text result

**Partial Transcription Result**:
A recording for which at least one requested transcript artifact succeeded while another failed. Successful artifacts remain available and only failed artifacts require retry.
_Avoid_: Failed recording, discarded partial result

**Transcribe Again**:
An explicit request to replace an existing recording's generated transcript from the same source while preserving its source captions and source identity.
_Avoid_: Duplicate import, transcript version
