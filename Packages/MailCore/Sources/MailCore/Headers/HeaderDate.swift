import Foundation

/// RFC 5322 §3.3 dates, plus the attribution line Gmail puts above a quoted reply.
public enum HeaderDate {

    private static let months = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]

    private static let namedZones: [String: Int] = [
        "UT": 0, "UTC": 0, "GMT": 0, "Z": 0,
        "EST": -5 * 3600, "EDT": -4 * 3600,
        "CST": -6 * 3600, "CDT": -5 * 3600,
        "MST": -7 * 3600, "MDT": -6 * 3600,
        "PST": -8 * 3600, "PDT": -7 * 3600,
    ]

    /// `Fri, 11 Sep 2026 10:00:00 +0200`.
    public static func rfc5322(_ date: Date, timeZone: TimeZone) -> String {
        formatter(format: "EEE, d MMM yyyy HH:mm:ss Z", timeZone: timeZone).string(from: date)
    }

    /// `Thu, Sep 10, 2026 at 9:12 AM`, with the narrow no-break space Gmail uses before the meridiem.
    public static func attribution(_ date: Date, timeZone: TimeZone) -> String {
        formatter(format: "EEE, MMM d, yyyy 'at' h:mm\u{202F}a", timeZone: timeZone).string(from: date)
    }

    /// Tolerant parse covering the obsolete forms still seen in the wild: missing day name, comments,
    /// two- and three-digit years, missing seconds, and named zones.
    public static func parse(_ value: String) -> Date? {
        var tokens = tokenize(value)

        if tokens.count >= 5, isAlphabetic(tokens[0]), isNumeric(tokens[1]) {
            tokens.removeFirst()
        } else if tokens.count >= 2, isAlphabetic(tokens[0]), isAlphabetic(tokens[1]) {
            return nil
        }

        guard tokens.count >= 4 else { return nil }
        guard let day = Int(tokens[0]),
            let monthIndex = months.firstIndex(of: tokens[1].prefix(3).lowercased()),
            var year = Int(tokens[2])
        else { return nil }

        if year < 50 {
            year += 2000
        } else if year < 1000 {
            year += 1900
        }

        let timeParts = tokens[3].split(separator: ":").map(String.init)
        guard timeParts.count == 2 || timeParts.count == 3,
            let hour = Int(timeParts[0]),
            let minute = Int(timeParts[1])
        else { return nil }
        let second = timeParts.count == 3 ? Int(timeParts[2]) : 0
        guard let second else { return nil }

        guard (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute),
            (0...60).contains(second)
        else { return nil }

        let zoneToken = tokens.count >= 5 ? tokens[4] : "+0000"
        let offset = zoneOffset(zoneToken)

        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(secondsFromGMT: offset) else { return nil }
        calendar.timeZone = zone
        let components = DateComponents(
            year: year,
            month: monthIndex + 1,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        return calendar.date(from: components)
    }

    private static func formatter(format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// Strips parenthesised comments, turns commas into spaces, collapses runs of whitespace.
    private static func tokenize(_ value: String) -> [String] {
        var withoutComments = ""
        var depth = 0
        for character in value {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                if depth > 0 { depth -= 1 }
            } else if depth == 0 {
                withoutComments.append(character == "," ? " " : character)
            }
        }
        return withoutComments.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
            .map(String.init)
    }

    private static func zoneOffset(_ token: String) -> Int {
        if let first = token.first, first == "+" || first == "-" {
            let digits = token.dropFirst()
            if digits.count == 4, let value = Int(digits) {
                let seconds = (value / 100) * 3600 + (value % 100) * 60
                return first == "-" ? -seconds : seconds
            }
            return 0
        }
        return namedZones[token.uppercased()] ?? 0
    }

    private static func isAlphabetic(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isLetter }
    }

    private static func isNumeric(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isNumber }
    }
}
