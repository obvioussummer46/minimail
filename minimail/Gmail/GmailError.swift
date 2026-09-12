import Foundation
import MailCore

/// Every failure a Gmail call can produce. Sendable + Equatable so `Result<T, GmailError>` values cross actors
/// and tests compare them.
nonisolated enum GmailError: Error, Sendable, Equatable, CustomStringConvertible {
    case offline
    case network(code: Int)
    case unauthorized
    case forbidden(reason: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case notFound
    case historyExpired
    case badRequest(reason: String?, message: String?)
    case server(status: Int)
    case decoding(String)
    case batchMalformed
    case cancelled

    /// offline, network, rateLimited, server, batchMalformed
    var isTransient: Bool {
        switch self {
        case .offline, .network, .rateLimited, .server, .batchMalformed: return true
        default: return false
        }
    }

    /// Everything except offline, cancelled, unauthorized (those never consume an outbox attempt).
    var countsAsAttempt: Bool {
        switch self {
        case .offline, .cancelled, .unauthorized: return false
        default: return true
        }
    }

    /// `.rateLimited(retryAfter: r)` → `r`; every other case → nil.
    var retryAfter: TimeInterval? {
        if case .rateLimited(let r) = self { return r }
        return nil
    }

    /// Short user-visible text for `SyncStatus.lastError` / outbox rows.
    var userMessage: String {
        switch self {
        case .offline: return "Offline"
        case .network: return "Network error"
        case .unauthorized: return "Sign in again"
        case .forbidden(let reason):
            return reason == "dailyLimitExceeded" ? "Daily quota exceeded" : "Access denied"
        case .rateLimited: return "Rate limited — try again later"
        case .notFound: return "Not found"
        case .historyExpired: return "Resyncing"
        case .badRequest: return "Request rejected"
        case .server: return "Gmail server error"
        case .decoding: return "Unexpected response"
        case .batchMalformed: return "Unexpected response"
        case .cancelled: return "Cancelled"
        }
    }

    /// Maps a non-2xx HTTP response. `endpoint` = path relative to the base URL without query.
    static func map(
        status: Int,
        body: Data,
        headers: [AnyHashable: Any],
        endpoint: String,
        now: Date = Date()
    ) -> GmailError {
        let env = try? JSONDecoder().decode(GmailErrorEnvelope.self, from: body)
        let reason = env?.primaryReason
        let message = env?.error.message
        let isHistory = endpoint == "history" || endpoint.hasSuffix("/history")
        let retryAfter = RetryAfterParser.seconds(headers, now)
        switch status {
        case 400:
            if isHistory && (reason == "failedPrecondition" || (message ?? "").lowercased().contains("historyid")) {
                return .historyExpired
            }
            return .badRequest(reason: reason, message: message)
        case 401:
            return .unauthorized
        case 403:
            let quota: Set<String> = [
                "rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded", "concurrentLimitExceeded",
            ]
            if let reason, quota.contains(reason) { return .rateLimited(retryAfter: retryAfter) }
            return .forbidden(reason: reason)
        case 404:
            return isHistory ? .historyExpired : .notFound
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 500...599:
            return .server(status: status)
        case 402, 405...428, 430...499:
            return .badRequest(reason: reason, message: message)
        default:
            return .badRequest(reason: nil, message: "unexpected status \(status)")
        }
    }

    /// Maps a transport error.
    static func map(_ urlError: URLError) -> GmailError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .cancelled:
            return .cancelled
        default:
            return .network(code: urlError.code.rawValue)
        }
    }
}

extension GmailError {
    nonisolated var description: String {
        switch self {
        case .offline: return "offline"
        case .network(let code): return "network(\(code))"
        case .unauthorized: return "unauthorized"
        case .forbidden(let reason): return "forbidden(\(reason ?? "nil"))"
        case .rateLimited(let r): return "rateLimited(retryAfter: \(r.map { "\($0)" } ?? "nil"))"
        case .notFound: return "notFound"
        case .historyExpired: return "historyExpired"
        case .badRequest(let reason, let message):
            return "badRequest(\(reason ?? "nil"): \(message ?? "nil"))"
        case .server(let status): return "server(\(status))"
        case .decoding(let text): return "decoding(\(text))"
        case .batchMalformed: return "batchMalformed"
        case .cancelled: return "cancelled"
        }
    }
}

/// Parses a `Retry-After` header value (delta-seconds or HTTP-date) into seconds from `now`.
nonisolated private enum RetryAfterParser {
    static func seconds(_ headers: [AnyHashable: Any], _ now: Date) -> TimeInterval? {
        guard
            let raw = headers.first(where: { ($0.key as? String)?.lowercased() == "retry-after" })?.value as? String
        else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(value) { return max(0, seconds) }
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss 'GMT'"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }
}
