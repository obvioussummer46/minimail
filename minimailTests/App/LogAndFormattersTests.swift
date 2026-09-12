import XCTest

@testable import minimail

private struct TestError: Error {}

nonisolated final class LogAndFormattersTests: XCTestCase {

    @MainActor
    func testLoggerCategoriesExist() {
        XCTAssertEqual(Log.subsystem, "de.newtelco.minimail")
        let loggers = [Log.auth, Log.net, Log.sync, Log.outbox, Log.db, Log.web, Log.ui, Log.bg]
        XCTAssertEqual(loggers.count, 8)
        XCTAssertEqual(Log.Interval.allCases.count, 8)
    }

    @MainActor
    func testIntervalNamesMatchCases() {
        for interval in Log.Interval.allCases {
            XCTAssertEqual("\(interval.name)", interval.rawValue)
        }
    }

    @MainActor
    func testMeasureReturnsValueAndEndsOnThrow() {
        let value = Log.measure(.threadOpen) { 42 }
        XCTAssertEqual(value, 42)
        XCTAssertThrowsError(
            try Log.measure(.bodyLoad) { () -> Int in throw TestError() }
        )
    }

    @MainActor
    func testMeasureAsync() async {
        let value = await Log.measure(.deltaSync) {
            await Task.yield()
            return "x"
        }
        XCTAssertEqual(value, "x")
    }

    @MainActor
    func testBytes() {
        XCTAssertFalse(Formatters.bytes(0).isEmpty)
        XCTAssertTrue(Formatters.bytes(1_500_000).hasSuffix("MB"))
        XCTAssertEqual(Formatters.bytes(-5), Formatters.bytes(0))
    }
}
