import Foundation

/// Half-open range [startMs, endMs) of one local calendar day in `timeZone`.
public struct DayBoundary: Sendable, Equatable {
    public let startMs: Int64
    public let endMs: Int64

    public init(startMs: Int64, endMs: Int64) {
        self.startMs = startMs
        self.endMs = endMs
    }

    /// `startMs = startOfDay(now)`, `endMs = startOfDay + 1 day` (23 h / 24 h / 25 h on DST days).
    public static func today(now: Date, timeZone: TimeZone, calendar: Calendar = Calendar(identifier: .gregorian))
        -> DayBoundary
    {
        var cal = calendar
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DayBoundary(
            startMs: Int64((start.timeIntervalSince1970 * 1000).rounded()),
            endMs: Int64((end.timeIntervalSince1970 * 1000).rounded())
        )
    }

    /// `startMs <= epochMs && epochMs < endMs`.
    public func contains(_ epochMs: Int64) -> Bool {
        startMs <= epochMs && epochMs < endMs
    }
}

public enum RowDateLabel {
    /// Convenience over `RowDateLabeler` (creates the formatters per call; use the labeler for lists).
    public static func label(epochMs: Int64, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        RowDateLabeler(now: now, timeZone: timeZone, locale: locale).label(epochMs: epochMs)
    }
}

/// Formats list-row dates; holds four `DateFormatter`s, so it is a class, NOT `Sendable`; create one per query.
public final class RowDateLabeler {
    private let cal: Calendar
    private let now: Date
    private let todayStart: Date
    private let yesterdayStart: Date
    private let weekStart: Date
    private let yearOfNow: Int
    private let time: DateFormatter
    private let weekday: DateFormatter
    private let dayMonth: DateFormatter
    private let shortDate: DateFormatter

    public init(now: Date, timeZone: TimeZone, locale: Locale, calendar: Calendar = Calendar(identifier: .gregorian)) {
        var cal = calendar
        cal.timeZone = timeZone
        cal.locale = locale
        self.cal = cal
        self.now = now
        self.todayStart = cal.startOfDay(for: now)
        self.yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
        self.weekStart = cal.date(byAdding: .day, value: -6, to: todayStart)!
        self.yearOfNow = cal.component(.year, from: now)

        func formatter(_ configure: (DateFormatter) -> Void) -> DateFormatter {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.calendar = cal
            configure(f)
            return f
        }
        self.time = formatter {
            $0.dateStyle = .none
            $0.timeStyle = .short
        }
        self.weekday = formatter { $0.setLocalizedDateFormatFromTemplate("EEE") }
        self.dayMonth = formatter { $0.setLocalizedDateFormatFromTemplate("d MMM") }
        self.shortDate = formatter {
            $0.dateStyle = .short
            $0.timeStyle = .none
        }
    }

    /// First match wins: today → short time; yesterday → "Yesterday"; last 6 days → weekday; same year → "d MMM";
    /// else short date.
    public func label(epochMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(epochMs) / 1000)
        if date >= todayStart && cal.isDate(date, inSameDayAs: now) {
            return time.string(from: date)
        }
        if date >= yesterdayStart && date < todayStart {
            return "Yesterday"
        }
        if date >= weekStart && date < yesterdayStart {
            return weekday.string(from: date)
        }
        if cal.component(.year, from: date) == yearOfNow {
            return dayMonth.string(from: date)
        }
        return shortDate.string(from: date)
    }
}
