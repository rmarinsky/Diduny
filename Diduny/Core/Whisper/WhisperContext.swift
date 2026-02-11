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

    func transcribe(samples: [Float], language: String? = nil, initialPrompt: String? = nil) throws -> String {
        guard let context else {
            throw WhisperError.contextNotInitialized
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        let threadCount = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        params.n_threads = Int32(threadCount)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.single_segment = false

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

        guard result == 0 else {
            Log.whisper.error("Whisper transcription failed with code: \(result)")
            throw WhisperError.transcriptionFailed
        }

        let segmentCount = whisper_full_n_segments(context)
        var text = ""

        for i in 0 ..< segmentCount {
            if let segmentText = whisper_full_get_segment_text(context, i) {
                text += String(cString: segmentText)
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.whisper.info("Transcription complete: \(trimmed.prefix(50))...")
        return trimmed
    }
}
