import Foundation

/// One call per user-visible failure: writes it to the local diagnostics log and,
/// with statistics sharing on, reports its code (never its message) to the backend.
@MainActor
enum IncidentReporter {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// "<engine>:<model>" for a route, e.g. "local-whisper:large-v3-turbo".
    static func engineLabel(_ route: RunTimeRoute) -> String {
        route.engine.rawValue + (route.modelID.map { ":" + $0 } ?? "")
    }

    /// Backend `kind` for a job.
    static func kind(_ job: STTJob) -> String {
        switch job {
        case .dictation: "dictation"
        case .dictationTranslation: "translation"
        case .meeting, .meetingTranslation: "meeting"
        case .file: "file"
        }
    }

    static func report(_ error: Error, kind: String, engine: String) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        let requestId = DiagnosticLog.shared.recentRequestId()
        var fields = DiagnosticLog.errorFields(error)
        fields[.kind] = .string(kind)
        fields[.engine] = .string(AnalyticsService.engineLabel(engine) ?? "unknown")
        if let requestId { fields[.requestId] = .string(requestId) }
        DiagnosticLog.shared.record(.failure, fields)
        let code = DiagnosticLog.errorCode(error)
        Task {
            await AnalyticsService.shared.recordError(
                kind: kind,
                engine: engine,
                errorCode: code,
                requestId: requestId,
                appVersion: appVersion
            )
        }
    }
}

extension AppDelegate {
    /// The engine label ("engine:model") the job routes to now, for analytics and incident reports.
    func analyticsEngine(for job: STTJob) -> String {
        IncidentReporter.engineLabel(modeRoute(for: job))
    }

    func reportFailure(_ error: Error, job: STTJob) {
        IncidentReporter.report(error, kind: IncidentReporter.kind(job), engine: analyticsEngine(for: job))
    }
}
