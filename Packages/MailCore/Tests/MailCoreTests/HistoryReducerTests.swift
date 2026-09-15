import XCTest

@testable import MailCore

final class HistoryReducerTests: XCTestCase {

    private func ref(_ id: String, thread: String? = nil, labels: [String]? = nil) -> GmailMessageRef {
        GmailMessageRef(id: id, threadId: thread, labelIds: labels)
    }
    private func add(_ r: GmailMessageRef) -> GmailHistoryMessageChange { GmailHistoryMessageChange(message: r) }
    private func lbl(_ r: GmailMessageRef, _ labels: [String]) -> GmailHistoryLabelChange {
        GmailHistoryLabelChange(message: r, labelIds: labels)
    }
    private func hist(
        _ id: UInt64, added: [GmailHistoryMessageChange]? = nil, deleted: [GmailHistoryMessageChange]? = nil,
        labelsAdded: [GmailHistoryLabelChange]? = nil, labelsRemoved: [GmailHistoryLabelChange]? = nil
    ) -> GmailHistory {
        GmailHistory(
            id: StringUInt64(id), messagesAdded: added, messagesDeleted: deleted, labelsAdded: labelsAdded,
            labelsRemoved: labelsRemoved)
    }
    private func page(_ historyId: UInt64?, _ records: [GmailHistory]?) -> GmailListHistoryResponse {
        GmailListHistoryResponse(history: records, historyId: historyId.map { StringUInt64($0) })
    }

    func testEmptyPages() {
        XCTAssertEqual(HistoryReducer.reduce([]), HistoryChanges())
        XCTAssertNil(HistoryReducer.reduce([]).newHistoryId)
    }

    func testEmptyHistoryKeepsHistoryId() {
        let c = HistoryReducer.reduce([page(2000, nil)])
        XCTAssertEqual(c.recordCount, 0)
        XCTAssertEqual(c.newHistoryId, 2000)
        XCTAssertTrue(c.added.isEmpty && c.deleted.isEmpty && c.labelOps.isEmpty)
    }

    func testAdded() {
        let c = HistoryReducer.reduce([
            page(2001, [hist(1, added: [add(ref("n1", thread: "n1", labels: ["UNREAD", "INBOX"]))])])
        ])
        XCTAssertEqual(c.added["n1"]?.labelIds, ["UNREAD", "INBOX"])
        XCTAssertEqual(c.finalLabels["n1"], ["UNREAD", "INBOX"])
        XCTAssertEqual(c.touchedThreads, ["n1"])
        XCTAssertTrue(c.deleted.isEmpty)
    }

    func testDeleted() {
        let c = HistoryReducer.reduce([page(2002, [hist(1, deleted: [add(ref("a1", thread: "a1"))])])])
        XCTAssertEqual(c.deleted, ["a1"])
        XCTAssertTrue(c.added.isEmpty)
        XCTAssertEqual(c.touchedThreads, ["a1"])
    }

    func testLabelsChronologicalAndFinal() {
        let c = HistoryReducer.reduce([
            page(
                2004,
                [
                    hist(1, labelsRemoved: [lbl(ref("a1", thread: "a1", labels: ["INBOX"]), ["UNREAD"])]),
                    hist(2, labelsAdded: [lbl(ref("b1", thread: "b1", labels: ["INBOX", "Label_12"]), ["Label_12"])]),
                ])
        ])
        XCTAssertEqual(c.labelOps["a1"], [LabelDelta(add: [], remove: ["UNREAD"])])
        XCTAssertEqual(c.finalLabels["a1"], ["INBOX"])
        XCTAssertEqual(c.labelOps["b1"], [LabelDelta(add: ["Label_12"], remove: [])])
        XCTAssertEqual(c.finalLabels["b1"], ["INBOX", "Label_12"])
        XCTAssertEqual(c.newHistoryId, 2004)
        XCTAssertEqual(c.recordCount, 2)
    }

    func testMixed() {
        let c = HistoryReducer.reduce([
            page(
                2010,
                [
                    hist(1, added: [add(ref("n2", thread: "n2", labels: ["INBOX"]))]),
                    hist(2, labelsRemoved: [lbl(ref("a1", thread: "a1", labels: ["UNREAD"]), ["INBOX"])]),
                    hist(3, deleted: [add(ref("c1", thread: "c1"))]),
                ])
        ])
        XCTAssertEqual(Set(c.added.keys), ["n2"])
        XCTAssertEqual(c.labelOps["a1"], [LabelDelta(add: [], remove: ["INBOX"])])
        XCTAssertEqual(c.finalLabels["a1"], ["UNREAD"])
        XCTAssertEqual(c.deleted, ["c1"])
        XCTAssertEqual(c.touchedThreads, ["n2", "a1", "c1"])
        XCTAssertEqual(c.newHistoryId, 2010)
        XCTAssertEqual(c.mentionedIds, ["n2", "a1", "c1"])
    }

    func testAddedThenDeletedCancels() {
        let c = HistoryReducer.reduce([
            page(
                2011,
                [
                    hist(1, added: [add(ref("n3", thread: "n3", labels: ["INBOX"]))]),
                    hist(2, deleted: [add(ref("n3", thread: "n3"))]),
                ])
        ])
        XCTAssertTrue(c.added.isEmpty)
        XCTAssertEqual(c.deleted, ["n3"])
        XCTAssertNil(c.finalLabels["n3"])
        XCTAssertNil(c.labelOps["n3"])
    }

    func testDeletedThenAddedReadds() {
        let c = HistoryReducer.reduce([
            page(
                2012,
                [
                    hist(1, deleted: [add(ref("x1", thread: "x1"))]),
                    hist(2, added: [add(ref("x1", thread: "x1", labels: ["INBOX"]))]),
                ])
        ])
        XCTAssertNotNil(c.added["x1"])
        XCTAssertTrue(c.deleted.isEmpty)
    }

    func testMultiPage() {
        let c = HistoryReducer.reduce([
            page(nil, [hist(1, added: [add(ref("n4", thread: "n4", labels: ["INBOX", "UNREAD"]))])]),
            page(
                2025,
                [
                    hist(
                        2,
                        labelsAdded: [
                            lbl(ref("n4", thread: "n4", labels: ["INBOX", "UNREAD", "STARRED"]), ["STARRED"])
                        ])
                ]),
        ])
        XCTAssertNotNil(c.added["n4"])
        XCTAssertEqual(c.labelOps["n4"], [LabelDelta(add: ["STARRED"], remove: [])])
        XCTAssertEqual(c.finalLabels["n4"], ["INBOX", "UNREAD", "STARRED"])
        XCTAssertEqual(c.newHistoryId, 2025)
        XCTAssertEqual(c.recordCount, 2)
    }

    func testLastAddedWins() {
        let c = HistoryReducer.reduce([
            page(
                2030,
                [
                    hist(1, added: [add(ref("y1", thread: "y1", labels: ["INBOX"]))]),
                    hist(2, added: [add(ref("y1", thread: "y1", labels: ["INBOX", "STARRED"]))]),
                ])
        ])
        XCTAssertEqual(c.added["y1"]?.labelIds, ["INBOX", "STARRED"])
        XCTAssertEqual(c.finalLabels["y1"], ["INBOX", "STARRED"])
    }

    func testTrashIsLabelChange() {
        let c = HistoryReducer.reduce([
            page(
                2040,
                [
                    hist(
                        1, labelsAdded: [lbl(ref("b1", thread: "b1", labels: ["INBOX", "UNREAD", "TRASH"]), ["TRASH"])]),
                    hist(2, labelsRemoved: [lbl(ref("b1", thread: "b1", labels: ["TRASH", "UNREAD"]), ["INBOX"])]),
                ])
        ])
        XCTAssertTrue(c.deleted.isEmpty)
        XCTAssertEqual(
            c.labelOps["b1"], [LabelDelta(add: ["TRASH"], remove: []), LabelDelta(add: [], remove: ["INBOX"])])
        XCTAssertEqual(c.finalLabels["b1"], ["TRASH", "UNREAD"])
    }

    func testOwnEchoWithoutLabelIds() {
        let c = HistoryReducer.reduce([
            page(
                2050,
                [
                    hist(1, labelsAdded: [lbl(ref("a1", thread: "a1", labels: ["INBOX"]), ["INBOX"])]),
                    hist(2, labelsRemoved: [lbl(ref("b1", thread: "b1", labels: nil), ["INBOX"])]),
                ])
        ])
        XCTAssertEqual(c.finalLabels["a1"], ["INBOX"])
        XCTAssertNil(c.finalLabels["b1"])
        XCTAssertEqual(c.labelOps["b1"], [LabelDelta(add: [], remove: ["INBOX"])])
    }

    func testRecordWithoutChangesCounts() {
        let c = HistoryReducer.reduce([page(2060, [hist(1)])])
        XCTAssertEqual(c.recordCount, 1)
        XCTAssertTrue(c.added.isEmpty && c.deleted.isEmpty && c.labelOps.isEmpty)
        XCTAssertEqual(c.newHistoryId, 2060)
    }
}
