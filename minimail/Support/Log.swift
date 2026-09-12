import Foundation
import os

/// Logger categories and signpost intervals.
///
/// `nonisolated` so that actors (auth, networking, sync) and GRDB reader closures can log without hopping
/// to the main actor.
///
/// Logging rules for every module: method, path, status and duration at `.debug`; retries and recoveries at
/// `.notice`; failures at `.error` with the error's description. Identifiers are `%{public}`, addresses,
/// subjects and snippets are `%{private}`. Tokens, headers and message bodies are never logged.
nonisolated enum Log {
    static let subsystem = "de.newtelco.minimail"

    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let net = Logger(subsystem: subsystem, category: "net")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let outbox = Logger(subsystem: subsystem, category: "outbox")
    static let db = Logger(subsystem: subsystem, category: "db")
    static let web = Logger(subsystem: subsystem, category: "web")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let bg = Logger(subsystem: subsystem, category: "bg")

    /// Category `.pointsOfInterest` so Instruments shows the intervals without extra configuration.
    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    /// The measured intervals. Raw values match the case names so logs and code read the same.
    enum Interval: String, CaseIterable, Sendable {
        case coldStartToList
        case fullSync
        case deltaSync
        case hydrateBatch
        case threadOpen
        case bodyLoad
        case documentLoad
        case outboxDrain

        var name: StaticString {
            switch self {
            case .coldStartToList: return "coldStartToList"
            case .fullSync: return "fullSync"
            case .deltaSync: return "deltaSync"
            case .hydrateBatch: return "hydrateBatch"
            case .threadOpen: return "threadOpen"
            case .bodyLoad: return "bodyLoad"
            case .documentLoad: return "documentLoad"
            case .outboxDrain: return "outboxDrain"
            }
        }
    }

    /// Begins an interval with a fresh signpost id, so intervals of the same name may overlap.
    static func begin(_ interval: Interval) -> OSSignpostIntervalState {
        signposter.beginInterval(interval.name, id: signposter.makeSignpostID())
    }

    /// Ends `state`. Ending the same state twice is a programmer error and trips an assertion in Debug.
    static func end(_ interval: Interval, _ state: OSSignpostIntervalState) {
        signposter.endInterval(interval.name, state)
    }

    static func measure<T>(_ interval: Interval, _ body: () throws -> T) rethrows -> T {
        let state = begin(interval)
        defer { end(interval, state) }
        return try body()
    }

    static func measure<T>(_ interval: Interval, _ body: () async throws -> T) async rethrows -> T {
        let state = begin(interval)
        defer { end(interval, state) }
        return try await body()
    }
}
