import Foundation

/// User-facing outcomes for ElevenLabs failures. Carries no key and no transcript text.
enum ElevenLabsError: Error, Equatable, LocalizedError {
    case invalidKey
    case missingPermission
    case planOrModelNotAvailable
    case termsNotAccepted
    case quotaExceeded
    case rateLimited
    case network
    /// Free-tier abuse flag: the provider message is shown verbatim (it contains no user data).
    case unusualActivity(message: String)
    case invalidResponse
    /// Realtime server error message type (e.g. `transcriber_error`); carries no user data.
    case sessionEnded(code: String)
    case unknown(status: Int, requestID: String?)

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            String(localized: "ElevenLabs rejected the API key")
        case .missingPermission:
            String(localized: "Key lacks permission: speech_to_text")
        case .planOrModelNotAvailable:
            String(localized: "Your ElevenLabs plan doesn't include this model")
        case .termsNotAccepted:
            String(localized: "Accept the Scribe terms in your ElevenLabs dashboard")
        case .quotaExceeded:
            String(localized: "ElevenLabs credits exhausted; wait for the reset or top up")
        case .rateLimited:
            String(localized: "ElevenLabs is busy or your plan's parallel limit is reached")
        case .network:
            String(localized: "Can't reach ElevenLabs")
        case let .unusualActivity(message):
            message + " " + String(localized: "If you use a VPN, turn it off and try again.")
        case .invalidResponse:
            String(localized: "ElevenLabs returned an unexpected response")
        case let .sessionEnded(code):
            String(format: String(localized: "ElevenLabs ended the live session (%@)"), code)
        case let .unknown(status, requestID):
            String(format: String(localized: "ElevenLabs error (HTTP %lld)"), Int64(status))
                + (requestID.map { " · \($0)" } ?? "")
        }
    }

    /// Maps an HTTP error response. Parses the modern `detail{type,code,status,message,request_id}`,
    /// the legacy `detail{status,message}` and the 422 `detail[{loc,msg,type}]` shapes.
    static func from(httpStatus: Int, body: Data) -> ElevenLabsError {
        let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["detail"] as? [String: Any]
        let code = (detail?["code"] as? String) ?? (detail?["status"] as? String) ?? ""
        let message = (detail?["message"] as? String) ?? ""
        let requestID = detail?["request_id"] as? String

        if message.localizedCaseInsensitiveContains("unusual activity") {
            return .unusualActivity(message: message)
        }
        if code.contains("terms") || message.localizedCaseInsensitiveContains("terms") {
            return .termsNotAccepted
        }
        if code == "quota_exceeded" || code == "insufficient_credits" { return .quotaExceeded }
        // A restricted key answers 401 `missing_permissions`: the key is valid, a permission is off.
        if code == "missing_permissions" { return .missingPermission }
        switch httpStatus {
        case 401: return .invalidKey
        case 402: return .quotaExceeded
        case 403:
            let planCodes = ["feature_not_available", "subscription_required", "model_access_denied"]
            return planCodes.contains(code) ? .planOrModelNotAvailable : .missingPermission
        case 429: return .rateLimited
        default: return .unknown(status: httpStatus, requestID: requestID)
        }
    }

    static func from(transportError error: Error) -> ElevenLabsError {
        if let error = error as? ElevenLabsError { return error }
        return .network
    }
}
