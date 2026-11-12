import Foundation
import os

// MARK: - HTTP Logger
// Every build sends X-Request-Id and writes failed calls (status, path, request ID;
// never bodies) to the exportable DiagnosticLog. Verbose logging is DEV_BUILD only.

enum HTTPLogger {
    /// Attaches an X-Request-Id header to the request for correlation with server logs.
    static func attachRequestId(_ request: inout URLRequest) -> String {
        let requestId = UUID().uuidString.lowercased()
        request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        return requestId
    }

    /// Records a non-2xx response in the diagnostics log.
    static func recordFailure(response: HTTPURLResponse, requestId: String) {
        guard !(200 ... 299).contains(response.statusCode) else { return }
        let serverRequestId = response.value(forHTTPHeaderField: "X-Request-Id") ?? requestId
        DiagnosticLog.shared.record(.httpError, [
            .httpStatus: .int(response.statusCode),
            .path: .string(response.url?.path ?? ""),
            .requestId: .string(serverRequestId),
        ])
    }

    #if DEV_BUILD
    /// Logs outgoing request: method, path, and body size for multipart.
    static func logRequest(_ request: URLRequest, requestId: String) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? "unknown"
        var message = "→ \(method) \(path) [rid:\(requestId.prefix(8))]"

        if let body = request.httpBody, body.count > 1024 {
            let sizeMB = Double(body.count) / (1024.0 * 1024.0)
            message += " body=\(String(format: "%.1f", sizeMB))MB"
        }

        Log.network.debug("\(message)")
    }

    /// Logs response: status, duration, and body preview on error.
    static func logResponse(
        data: Data,
        response: HTTPURLResponse,
        requestId: String,
        startTime: ContinuousClock.Instant
    ) {
        recordFailure(response: response, requestId: requestId)
        let duration = startTime.duration(to: .now)
        let ms = Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
        let serverRequestId = response.value(forHTTPHeaderField: "X-Request-Id") ?? requestId.prefix(8).description
        let status = response.statusCode

        var message = "← \(status) [\(ms)ms] [rid:\(serverRequestId.prefix(8))]"

        if !(200...299).contains(status) {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            message += " body: \(preview)"
        }

        if (200...299).contains(status) {
            Log.network.debug("\(message)")
        } else {
            Log.network.warning("\(message)")
        }
    }
    #else
    @inline(__always)
    static func logRequest(_: URLRequest, requestId _: String) {}

    static func logResponse(data _: Data, response: HTTPURLResponse, requestId: String, startTime _: ContinuousClock.Instant) {
        recordFailure(response: response, requestId: requestId)
    }
    #endif
}
