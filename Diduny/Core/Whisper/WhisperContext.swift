import Foundation

actor WhisperContext {
    private var context: OpaquePointer?

    init(modelPath: String) throws {
        var params = whisper_context_default_params()
        params.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            Log.whisper.error("Failed to load model from: \(modelPath)")
            throw WhisperError.modelLoadFailed
        }

        self.context = ctx
        Log.whisper.info("Whisper model loaded from: \(modelPath)")
    }

    deinit {
        if let context {
            whisper_free(context)
        }
    }

    static func milliseconds(fromTimestamp timestamp: Int64) -> Int {
        Int(timestamp) * 10
    }

    /// Holds the progress handler for whisper.cpp's C callback, which can't capture context.
    private final class ProgressHandlerBox {
        let handler: (Int) -> Void
        init(_ handler: @escaping (Int) -> Void) { self.handler = handler }
    }

    /// Set from the task's cancellation handler, read by whisper.cpp's abort callback on its own thread.
    final class AbortFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var aborted = false

        var isAborted: Bool { lock.withLock { aborted } }
        func abort() { lock.withLock { aborted = true } }

        /// The C callback whisper.cpp polls between compute steps; true stops the run.
        static let callback: ggml_abort_callback = { isAborted($0) }

        static func isAborted(_ userData: UnsafeMutableRawPointer?) -> Bool {
            guard let userData else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(userData).takeUnretainedValue().isAborted
        }
    }

    /// `onProgress` receives 0…100 from whisper.cpp's worker thread.
    /// Cancelling the calling task stops whisper.cpp mid-run and throws `CancellationError`.
    func transcribe(
        samples: [Float],
        language: String? = nil,
        initialPrompt: String? = nil,
        translate: Bool = false,
        onProgress: ((Int) -> Void)? = nil
    ) async throws -> GeneratedTranscript {
        let flag = AbortFlag()
        return try await withTaskCancellationHandler {
            try run(samples: samples, language: language, initialPrompt: initialPrompt, translate: translate,
                    onProgress: onProgress, abort: flag)
        } onCancel: {
            flag.abort()
        }
    }

    private func run(
        samples: [Float],
        language: String?,
        initialPrompt: String?,
        translate: Bool,
        onProgress: ((Int) -> Void)?,
        abort: AbortFlag
    ) throws -> GeneratedTranscript {
        guard let context else {
            throw WhisperError.contextNotInitialized
        }
        try Task.checkCancellation()

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        let threadCount = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        params.n_threads = Int32(threadCount)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = false
        params.single_segment = false
        params.translate = translate

        let progressBox = onProgress.map(ProgressHandlerBox.init)
        if let progressBox {
            params.progress_callback = { _, _, progress, userData in
                guard let userData else { return }
                Unmanaged<ProgressHandlerBox>.fromOpaque(userData).takeUnretainedValue().handler(Int(progress))
            }
            params.progress_callback_user_data = Unmanaged.passUnretained(progressBox).toOpaque()
        }
        defer { withExtendedLifetime(progressBox) {} }
        params.abort_callback = AbortFlag.callback
        params.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()
        defer { withExtendedLifetime(abort) {} }

        let languageCString = Array((language ?? "auto").utf8CString)
        let promptCString = initialPrompt.map { Array($0.utf8CString) }

        Log.whisper.info("Starting transcription: \(samples.count) samples, threads=\(threadCount), language=\(language ?? "auto"), prompt=\(initialPrompt?.prefix(40) ?? "none")")

        let result = languageCString.withUnsafeBufferPointer { langBuf in
            params.language = langBuf.baseAddress

            let runWhisper = { () -> Int32 in
                samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }

            if let promptCString {
                return promptCString.withUnsafeBufferPointer { promptBuf in
                    params.initial_prompt = promptBuf.baseAddress
                    return runWhisper()
                }
            } else {
                return runWhisper()
            }
        }

        if abort.isAborted {
            Log.whisper.info("Whisper transcription stopped: the task was cancelled")
            throw CancellationError()
        }
        guard result == 0 else {
            Log.whisper.error("Whisper transcription failed with code: \(result)")
            throw WhisperError.transcriptionFailed
        }

        let segmentCount = whisper_full_n_segments(context)
        var text = ""
        var segments: [TimedTranscriptSegment] = []

        for i in 0 ..< segmentCount {
            if let segmentText = whisper_full_get_segment_text(context, i) {
                let segmentText = String(cString: segmentText)
                text += segmentText
                let segment = TimedTranscriptSegment(
                    startMilliseconds: Self.milliseconds(
                        fromTimestamp: whisper_full_get_segment_t0(context, i)
                    ),
                    endMilliseconds: Self.milliseconds(
                        fromTimestamp: whisper_full_get_segment_t1(context, i)
                    ),
                    text: segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                if !segment.text.isEmpty {
                    segments.append(segment)
                }
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.whisper.info("Transcription complete: \(trimmed.prefix(50))...")
        return GeneratedTranscript(text: trimmed, segments: segments)
    }
}
