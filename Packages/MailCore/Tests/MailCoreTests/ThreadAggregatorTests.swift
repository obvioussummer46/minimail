import XCTest

@testable import MailCore

final class ThreadAggregatorTests: XCTestCase {

    private func input(
        _ id: String, t: Int64, subject: String = "s", snippet: String = "", fromName: String? = nil,
        fromAddr: String = "x@x", isFromMe: Bool = false, isUnread: Bool = false, inInbox: Bool = false,
        hasAttachments: Bool = false, bodyState: Int = 1, labels: Set<String> = []
    ) -> AggregateInput {
        AggregateInput(
            id: id, internalDate: t, subject: subject, snippet: snippet, fromName: fromName, fromAddr: fromAddr,
            isFromMe: isFromMe, isUnread: isUnread, inInbox: inInbox, hasAttachments: hasAttachments,
            bodyState: bodyState, labelIds: labels)
    }

    private func agg(_ messages: [AggregateInput], self selfAddresses: Set<String> = []) -> ThreadAggregate {
        ThreadAggregator.aggregate(messages, selfAddresses: selfAddresses)!
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ThreadAggregator.aggregate([], selfAddresses: []))
    }

    func testSubjectFromOldestStripped() {
        let a = agg([input("m1", t: 1, subject: "Re: Fwd: Angebot"), input("m2", t: 2, subject: "AW: Angebot")])
        XCTAssertEqual(a.subject, "Angebot")
    }

    func testSnippetFromNewest() {
        let a = agg([input("m2", t: 2, snippet: "new"), input("m1", t: 1, snippet: "old")])
        XCTAssertEqual(a.snippet, "new")
        XCTAssertEqual(a.lastDate, 2)
    }

    func testCounts() {
        let a = agg([
            input("m1", t: 1, isUnread: true, bodyState: 0),
            input("m2", t: 2, isUnread: true, hasAttachments: true, bodyState: 1),
            input("m3", t: 3, isUnread: false, bodyState: 2),
        ])
        XCTAssertEqual(a.messageCount, 3)
        XCTAssertEqual(a.unreadCount, 2)
        XCTAssertTrue(a.hasAttachments)
        XCTAssertEqual(a.bodiesMissing, 1)
    }

    func testLastInboxDateIgnoresNonInboxAndSelfSent() {
        let a = agg([
            input("m1", t: 1, fromAddr: "alice@x", inInbox: true),
            input("m2", t: 2, isFromMe: true, inInbox: true),
            input("m3", t: 3, inInbox: false),
        ])
        XCTAssertEqual(a.lastInboxDate, 1)
        XCTAssertTrue(a.inInbox)
        XCTAssertEqual(a.lastDate, 3)
    }

    func testLastInboxDateNilWhenNone() {
        let a = agg([input("m1", t: 1, inInbox: false)])
        XCTAssertNil(a.lastInboxDate)
        XCTAssertFalse(a.inInbox)
    }

    func testLastInboxDateSelfViaSelfAddresses() {
        let a = agg(
            [input("m1", t: 1, fromAddr: "Me@example.com", isFromMe: false, inInbox: true)],
            self: ["me@example.com"])
        XCTAssertNil(a.lastInboxDate)
        XCTAssertEqual(a.participants, "Me")
    }

    func testParticipantsOrderDedupeMe() {
        let a = agg([
            input("m1", t: 1, fromName: "Alice", fromAddr: "alice@example.com"),
            input("m2", t: 2, fromAddr: "me@x", isFromMe: true),
            input("m3", t: 3, fromName: "Alice", fromAddr: "Alice@Example.com"),
            input("m4", t: 4, fromName: "Bob", fromAddr: "bob@x"),
        ])
        XCTAssertEqual(a.participants, "Alice, Me, Bob")
    }

    func testParticipantsMaxThree() {
        let a = agg([
            input("m1", t: 1, fromName: "Alice", fromAddr: "alice@x"),
            input("m2", t: 2, fromName: "Bob", fromAddr: "bob@x"),
            input("m3", t: 3, fromName: "Carol", fromAddr: "carol@x"),
            input("m4", t: 4, fromName: "Dave", fromAddr: "dave@x"),
        ])
        XCTAssertEqual(a.participants, "Alice, Bob, Carol\u{2026}")
    }

    func testFirstNameRules() {
        XCTAssertEqual(ThreadAggregator.firstName(name: "Alice Müller", addr: "a@x"), "Alice")
        XCTAssertEqual(ThreadAggregator.firstName(name: "Müller, Bob", addr: "b@x"), "Bob")
        XCTAssertEqual(ThreadAggregator.firstName(name: "\"Carol Q\"", addr: "c@x"), "Carol")
        XCTAssertEqual(ThreadAggregator.firstName(name: nil, addr: "dave@x"), "dave")
        XCTAssertEqual(ThreadAggregator.firstName(name: "  ", addr: "eve@x"), "eve")
        XCTAssertEqual(ThreadAggregator.firstName(name: nil, addr: ""), "?")
    }

    func testUserLabelIdsAndAllLabelIds() {
        let a = agg([
            input("m1", t: 1, labels: ["INBOX", "Label_2"]),
            input("m2", t: 2, labels: ["Label_1", "UNREAD", "CATEGORY_UPDATES"]),
        ])
        XCTAssertEqual(a.userLabelIds, ["Label_1", "Label_2"])
        XCTAssertEqual(a.allLabelIds, ["CATEGORY_UPDATES", "INBOX", "Label_1", "Label_2", "UNREAD"])
    }

    func testInputOrderIndependent() {
        let messages = [
            input("m1", t: 1, fromName: "Alice", fromAddr: "alice@x", inInbox: true, labels: ["INBOX"]),
            input("m2", t: 2, fromName: "Bob", fromAddr: "bob@x", isUnread: true, labels: ["UNREAD"]),
            input("m3", t: 3, fromName: "Carol", fromAddr: "carol@x", labels: ["Label_1"]),
            input("m4", t: 4, fromName: "Dave", fromAddr: "dave@x"),
        ]
        let base = agg(messages)
        XCTAssertEqual(base, agg(messages.reversed()))
        XCTAssertEqual(base, agg([messages[2], messages[0], messages[3], messages[1]]))
    }
}
