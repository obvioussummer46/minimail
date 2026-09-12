import XCTest

@testable import MailCore

final class DayBoundaryTests: XCTestCase {

    private struct TodayVectors: Decodable {
        struct Case: Decodable {
            var name: String
            var tz: String
            var now: String
            var startMs: Int64
            var endMs: Int64
        }
        var cases: [Case]
    }

    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func parseISO(_ s: String) -> Date {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)!
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0, tz: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (y, mo, d, h, mi, s)
        return cal.date(from: c)!
    }

    private func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    func testVectors() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "today", withExtension: "json", subdirectory: "Fixtures/vectors"))
        let vectors = try JSONDecoder().decode(TodayVectors.self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.cases.count, 7)
        for c in vectors.cases {
            let tz = try XCTUnwrap(TimeZone(identifier: c.tz))
            let boundary = DayBoundary.today(now: parseISO(c.now), timeZone: tz)
            XCTAssertEqual(boundary, DayBoundary(startMs: c.startMs, endMs: c.endMs), c.name)
        }
    }

    func testDSTLengths() {
        let h = Int64(3_600_000)
        let dstStart = DayBoundary.today(now: date(2026, 3, 29, 12, 0, tz: berlin), timeZone: berlin)
        XCTAssertEqual(dstStart.endMs - dstStart.startMs, 23 * h)
        let dstEnd = DayBoundary.today(now: date(2026, 10, 25, 12, 0, tz: berlin), timeZone: berlin)
        XCTAssertEqual(dstEnd.endMs - dstEnd.startMs, 25 * h)
        let akl = TimeZone(identifier: "Pacific/Auckland")!
        let aklDay = DayBoundary.today(now: date(2026, 9, 27, 5, 0, tz: akl), timeZone: akl)
        XCTAssertEqual(aklDay.endMs - aklDay.startMs, 23 * h)
    }

    func testContainsEdges() {
        let b = DayBoundary.today(now: date(2026, 9, 11, 13, 0, tz: berlin), timeZone: berlin)
        XCTAssertTrue(b.contains(b.startMs))
        XCTAssertTrue(b.contains(b.endMs - 1))
        XCTAssertFalse(b.contains(b.endMs))
        XCTAssertFalse(b.contains(b.startMs - 1))
    }

    // MARK: RowDateLabeler

    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    private func reference(_ template: String, _ date: Date, _ locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = berlin
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    private func shortDateReference(_ date: Date, _ locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = berlin
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: date)
    }

    func testLabelTodayTime() {
        let now = date(2026, 9, 11, 15, 0, tz: berlin)
        let msg = ms(date(2026, 9, 11, 14, 32, tz: berlin))
        XCTAssertEqual(RowDateLabeler(now: now, timeZone: berlin, locale: de).label(epochMs: msg), "14:32")
        let enLabel = RowDateLabeler(now: now, timeZone: berlin, locale: en).label(epochMs: msg)
        XCTAssertNotNil(enLabel.range(of: #"^2:32[ \x{202F}]PM$"#, options: .regularExpression), enLabel)
    }

    func testLabelYesterdayAcrossMidnight() {
        let now = date(2026, 9, 12, 0, 0, 30, tz: berlin)
        let msg = ms(date(2026, 9, 11, 23, 59, 59, tz: berlin))
        XCTAssertEqual(RowDateLabeler(now: now, timeZone: berlin, locale: en).label(epochMs: msg), "Yesterday")
    }

    func testLabelWeekday() {
        let now = date(2026, 9, 11, 15, 0, tz: berlin)  // Friday
        let labeler = RowDateLabeler(now: now, timeZone: berlin, locale: en)
        let mon = date(2026, 9, 7, 10, 0, tz: berlin)
        let sixDaysAgo = date(2026, 9, 5, 10, 0, tz: berlin)
        let sevenDaysAgo = date(2026, 9, 4, 10, 0, tz: berlin)
        XCTAssertEqual(labeler.label(epochMs: ms(mon)), reference("EEE", mon, en))
        XCTAssertEqual(labeler.label(epochMs: ms(sixDaysAgo)), reference("EEE", sixDaysAgo, en))
        XCTAssertEqual(labeler.label(epochMs: ms(sevenDaysAgo)), reference("d MMM", sevenDaysAgo, en))
    }

    func testLabelSameYear() {
        let now = date(2026, 9, 11, 15, 0, tz: berlin)
        let msg = date(2026, 1, 15, 10, 0, tz: berlin)
        XCTAssertEqual(
            RowDateLabeler(now: now, timeZone: berlin, locale: en).label(epochMs: ms(msg)),
            reference("d MMM", msg, en))
        XCTAssertTrue(RowDateLabeler(now: now, timeZone: berlin, locale: de).label(epochMs: ms(msg)).contains("15"))
        XCTAssertTrue(RowDateLabeler(now: now, timeZone: berlin, locale: en).label(epochMs: ms(msg)).contains("Jan"))
    }

    func testLabelOtherYear() {
        let now = date(2026, 9, 11, 15, 0, tz: berlin)
        let msg = date(2025, 9, 11, 10, 0, tz: berlin)
        XCTAssertEqual(RowDateLabeler(now: now, timeZone: berlin, locale: de).label(epochMs: ms(msg)), "11.09.25")
        XCTAssertEqual(
            RowDateLabeler(now: now, timeZone: berlin, locale: en).label(epochMs: ms(msg)),
            shortDateReference(msg, en))
    }

    func testLabelFutureSameDay() {
        let now = date(2026, 9, 11, 15, 0, tz: berlin)
        let msg = date(2026, 9, 11, 16, 0, tz: berlin)
        let labeler = RowDateLabeler(now: now, timeZone: berlin, locale: de)
        XCTAssertEqual(labeler.label(epochMs: ms(msg)), "16:00")
    }

    func testStaticMatchesLabeler() {
        let now = date(2026, 9, 11, 15, 0, tz: berlin)
        let labeler = RowDateLabeler(now: now, timeZone: berlin, locale: en)
        for d in [
            date(2026, 9, 11, 14, 0, tz: berlin), date(2026, 9, 10, 14, 0, tz: berlin),
            date(2026, 9, 7, 14, 0, tz: berlin), date(2026, 3, 1, 14, 0, tz: berlin),
            date(2024, 3, 1, 14, 0, tz: berlin),
        ] {
            XCTAssertEqual(
                RowDateLabel.label(epochMs: ms(d), now: now, timeZone: berlin, locale: en),
                labeler.label(epochMs: ms(d)))
        }
    }
}
