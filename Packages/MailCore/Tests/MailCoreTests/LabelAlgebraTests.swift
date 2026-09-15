import XCTest

@testable import MailCore

final class LabelAlgebraTests: XCTestCase {

    func testAppliedRemovesThenAdds() {
        let delta = LabelDelta(add: ["A"], remove: ["A", "B"])
        XCTAssertEqual(delta.applied(to: ["B", "C"]), ["A", "C"])
    }

    func testEffectiveFoldsInOrder() {
        let e = LabelAlgebra.effective(
            server: ["INBOX", "UNREAD"],
            pending: [
                LabelDelta(remove: ["UNREAD"]),
                LabelDelta(add: ["UNREAD"]),
                LabelDelta(remove: ["INBOX"]),
            ]
        )
        XCTAssertEqual(e, ["UNREAD"])
    }

    func testEffectiveNoPending() {
        XCTAssertEqual(LabelAlgebra.effective(server: ["X"], pending: []), ["X"])
    }

    func testFlagsMatrix() {
        XCTAssertEqual(LabelAlgebra.flags([]), DerivedFlags(isUnread: false, inInbox: false, isHidden: false))
        XCTAssertEqual(LabelAlgebra.flags(["UNREAD"]), DerivedFlags(isUnread: true, inInbox: false, isHidden: false))
        XCTAssertEqual(LabelAlgebra.flags(["INBOX"]), DerivedFlags(isUnread: false, inInbox: true, isHidden: false))
        XCTAssertEqual(LabelAlgebra.flags(["TRASH"]), DerivedFlags(isUnread: false, inInbox: false, isHidden: true))
        XCTAssertEqual(
            LabelAlgebra.flags(["SPAM", "INBOX", "UNREAD"]),
            DerivedFlags(isUnread: true, inInbox: true, isHidden: true))
        XCTAssertEqual(LabelAlgebra.flags(["DRAFT"]), DerivedFlags(isUnread: false, inInbox: false, isHidden: true))
        XCTAssertEqual(LabelAlgebra.flags(["CHAT"]), DerivedFlags(isUnread: false, inInbox: false, isHidden: true))
    }

    func testSortedJSONBytes() {
        XCTAssertEqual(LabelAlgebra.sortedJSON(["UNREAD", "INBOX", "Label_12"]), "[\"INBOX\",\"Label_12\",\"UNREAD\"]")
        XCTAssertEqual(LabelAlgebra.sortedJSON([]), "[]")
    }

    func testSortedJSONEscaping() {
        XCTAssertEqual(LabelAlgebra.sortedJSON(["a\"b", "c/d", "é"]), "[\"a\\\"b\",\"c/d\",\"é\"]")
    }

    func testParseJSONRoundTripAndMalformed() {
        let s: Set<String> = ["INBOX", "Label_12", "UNREAD"]
        XCTAssertEqual(LabelAlgebra.parseJSON(LabelAlgebra.sortedJSON(s)), s)
        XCTAssertEqual(LabelAlgebra.parseJSON("nope"), [])
        XCTAssertEqual(LabelAlgebra.parseJSON("[1]"), [])
    }

    func testUserVisible() {
        let labels: Set<String> = [
            "Label_2", "INBOX", "CATEGORY_PROMOTIONS", "Label_1", "STARRED", "IMPORTANT", "SENT", "UNREAD", "DRAFT",
            "CHAT", "SPAM", "TRASH",
        ]
        XCTAssertEqual(LabelAlgebra.userVisible(labels), ["Label_1", "Label_2"])
        XCTAssertTrue(LabelAlgebra.isSystem("CATEGORY_X"))
        XCTAssertFalse(LabelAlgebra.isSystem("Label_1"))
    }

    func testLabelDeltaCodableSorted() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(LabelDelta(add: ["B", "A"], remove: ["Z"]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"add\":[\"A\",\"B\"],\"remove\":[\"Z\"]}")

        let decoded = try JSONDecoder().decode(LabelDelta.self, from: data)
        XCTAssertEqual(decoded, LabelDelta(add: ["A", "B"], remove: ["Z"]))

        let dupes = try JSONDecoder().decode(
            LabelDelta.self, from: Data("{\"add\":[\"A\",\"A\"],\"remove\":[]}".utf8))
        XCTAssertEqual(dupes.add, ["A"])
    }

    func testIsEmpty() {
        XCTAssertTrue(LabelDelta().isEmpty)
        XCTAssertFalse(LabelDelta(add: ["A"]).isEmpty)
    }
}
