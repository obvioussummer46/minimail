import XCTest

@testable import MailCore

final class OutboxCoalescerTests: XCTestCase {

    func testInverseCancels() {
        let merged = OutboxCoalescer.merge(existing: LabelDelta(remove: ["UNREAD"]), new: LabelDelta(add: ["UNREAD"]))
        XCTAssertTrue(merged.isEmpty)
    }

    func testArchiveThenRead() {
        let merged = OutboxCoalescer.merge(existing: LabelDelta(remove: ["INBOX"]), new: LabelDelta(remove: ["UNREAD"]))
        XCTAssertEqual(merged.add, [])
        XCTAssertEqual(merged.remove, ["INBOX", "UNREAD"])
    }

    func testNewIntentWins() {
        // Archive (remove INBOX) then unarchive+read (add INBOX, remove UNREAD): the INBOX churn cancels,
        // leaving only the mark-read. (Cancelling coalescer — see OutboxCoalescer note.)
        let merged = OutboxCoalescer.merge(
            existing: LabelDelta(remove: ["INBOX"]),
            new: LabelDelta(add: ["INBOX"], remove: ["UNREAD"]))
        XCTAssertEqual(merged.add, [])
        XCTAssertEqual(merged.remove, ["UNREAD"])
    }

    func testIdempotent() {
        let delta = LabelDelta(add: ["A"], remove: ["B"])
        XCTAssertEqual(OutboxCoalescer.merge(existing: delta, new: delta), delta)
    }

    func testMergeIntoEmpty() {
        let d = LabelDelta(add: ["A"], remove: ["B"])
        XCTAssertEqual(OutboxCoalescer.merge(existing: LabelDelta(), new: d), d)
    }
}
