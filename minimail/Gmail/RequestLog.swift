import Foundation
import os

/// Ring buffer of the last 100 requests (architecture §6.5). Thread-safe via `OSAllocatedUnfairLock`; never
/// stores tokens, headers or bodies.
nonisolated final class RequestLog: Sendable {
    struct Entry: Sendable, Equatable {
        var date: Date
        var method: String
        var path: String
        var status: Int
        var ms: Int
    }

    static let capacity = 100

    private let buffer = OSAllocatedUnfairLock<[Entry]>(initialState: [])
    private let formatter: DateFormatter

    init() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        f.timeZone = .current
        formatter = f
    }

    /// Appends; drops the oldest entry beyond `capacity`.
    func record(method: String, path: String, status: Int, ms: Int) {
        let entry = Entry(date: Date(), method: method, path: path, status: status, ms: ms)
        buffer.withLock { entries in
            entries.append(entry)
            if entries.count > Self.capacity {
                entries.removeFirst(entries.count - Self.capacity)
            }
        }
    }

    /// Oldest → newest, formatted "HH:mm:ss.SSS METHOD path status msms".
    func snapshot() -> [String] {
        entries().map { entry in
            "\(formatter.string(from: entry.date)) \(entry.method) \(entry.path) \(entry.status) \(entry.ms)ms"
        }
    }

    /// Oldest → newest raw entries.
    func entries() -> [Entry] {
        buffer.withLock { $0 }
    }
}
