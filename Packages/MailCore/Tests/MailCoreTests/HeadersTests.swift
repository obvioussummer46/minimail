import XCTest

@testable import MailCore

final class MailboxTests: XCTestCase {

    func testSerializedForms() {
        XCTAssertEqual(
            Mailbox(name: "Max Mustermann", addr: "max.mustermann@newtelco.de").serialized(),
            "Max Mustermann <max.mustermann@newtelco.de>"
        )
        XCTAssertEqual(
            Mailbox(name: "Müller, Alice", addr: "alice@example.com").serialized(),
            "=?UTF-8?B?TcO8bGxlciwgQWxpY2U=?= <alice@example.com>"
        )
        XCTAssertEqual(
            Mailbox(name: "J. Doe", addr: "j@example.com").serialized(),
            "\"J. Doe\" <j@example.com>"
        )
        XCTAssertEqual(
            Mailbox(name: "Bob \"The Builder\"", addr: "bob@example.com").serialized(),
            "\"Bob \\\"The Builder\\\"\" <bob@example.com>"
        )
        XCTAssertEqual(Mailbox(name: nil, addr: "bob@example.com").serialized(), "bob@example.com")
        XCTAssertEqual(Mailbox(name: "   ", addr: "bob@example.com").serialized(), "bob@example.com")
    }

    func testKeyAndDisplayName() {
        let mailbox = Mailbox(name: nil, addr: "Bob@Example.COM")
        XCTAssertEqual(mailbox.key, "bob@example.com")
        XCTAssertEqual(mailbox.displayName, "Bob@Example.COM")
        XCTAssertEqual(Mailbox(name: "Bob", addr: "b@x").displayName, "Bob")
    }
}

final class AddressParserTests: XCTestCase {

    func testSimpleList() {
        let list = AddressParser.parseList(
            "Alice Müller <alice@example.com>, bob@example.com"
        )
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0], Mailbox(name: "Alice Müller", addr: "alice@example.com"))
        XCTAssertEqual(list[1], Mailbox(name: nil, addr: "bob@example.com"))
    }

    func testEncodedDisplayName() {
        let list = AddressParser.parseList("=?UTF-8?B?TcO8bGxlciwgQWxpY2U=?= <alice@example.com>")
        XCTAssertEqual(list.first?.name, "Müller, Alice")
        XCTAssertEqual(list.first?.addr, "alice@example.com")
    }

    func testCommaInsideQuotedNameDoesNotSplit() {
        let list = AddressParser.parseList("\"Mustermann, Max\" <max@newtelco.de>, bob@example.com")
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].name, "Mustermann, Max")
    }

    func testGroupIsFlattened() {
        let list = AddressParser.parseList("Team: max.mustermann@newtelco.de, bob@example.com;")
        XCTAssertEqual(list.map(\.addr), ["max.mustermann@newtelco.de", "bob@example.com"])
    }

    func testEmptyGroup() {
        XCTAssertTrue(AddressParser.parseList("undisclosed-recipients:;").isEmpty)
    }

    func testNullMembersDropped() {
        let list = AddressParser.parseList("bob@example.com,, ,carol@partner.example")
        XCTAssertEqual(list.map(\.addr), ["bob@example.com", "carol@partner.example"])
    }

    func testObsoleteRouteDropped() {
        let list = AddressParser.parseList("Bob <@relay.example:bob@example.com>")
        XCTAssertEqual(list.first, Mailbox(name: "Bob", addr: "bob@example.com"))
    }

    func testLegacyCommentName() {
        let list = AddressParser.parseList("bob@example.com (Bob Builder)")
        XCTAssertEqual(list.first, Mailbox(name: "Bob Builder", addr: "bob@example.com"))
    }

    func testParenthesesInsideQuotesAreNotComments() {
        let list = AddressParser.parseList("\"Alice (Sales)\" <a@b.example>")
        XCTAssertEqual(list.first?.name, "Alice (Sales)")
    }

    func testFoldedHeaderIsUnfolded() {
        let list = AddressParser.parseList("Alice\r\n <alice@example.com>")
        XCTAssertEqual(list.first, Mailbox(name: "Alice", addr: "alice@example.com"))
    }

    func testParseFirst() {
        XCTAssertEqual(AddressParser.parseFirst("a@x.example, b@y.example")?.addr, "a@x.example")
        XCTAssertNil(AddressParser.parseFirst(""))
    }
}

final class HeaderDateTests: XCTestCase {

    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    func testRFC5322Formatting() {
        let date = Date(timeIntervalSince1970: 1_789_113_600)
        XCTAssertEqual(HeaderDate.rfc5322(date, timeZone: berlin), "Fri, 11 Sep 2026 10:00:00 +0200")
        XCTAssertEqual(
            HeaderDate.rfc5322(date, timeZone: TimeZone(identifier: "UTC")!),
            "Fri, 11 Sep 2026 08:00:00 +0000"
        )
    }

    func testAttributionUsesNarrowNoBreakSpace() {
        let date = Date(timeIntervalSince1970: 1_789_024_353)
        XCTAssertEqual(HeaderDate.attribution(date, timeZone: berlin), "Thu, Sep 10, 2026 at 9:12\u{202F}AM")
    }

    func testParseAcceptedForms() {
        let expected = Date(timeIntervalSince1970: 1_789_024_353)
        XCTAssertEqual(HeaderDate.parse("Thu, 10 Sep 2026 09:12:33 +0200"), expected)
        XCTAssertEqual(HeaderDate.parse("10 Sep 2026 09:12:33 +0200"), expected)
        XCTAssertEqual(HeaderDate.parse("Thu, 10 Sep 2026 07:12:33 GMT"), expected)
        XCTAssertEqual(HeaderDate.parse("Thu, 10 Sep 2026 03:12:33 EDT"), expected)
        XCTAssertEqual(HeaderDate.parse("Thu, 10 Sep 2026 09:12:33 +0200 (CEST)"), expected)
        XCTAssertEqual(HeaderDate.parse("Thu,10 Sep 2026 09:12:33 +0200"), expected)
        XCTAssertEqual(
            HeaderDate.parse("Thu, 10 Sep 26 09:12 +0200"),
            Date(timeIntervalSince1970: 1_789_024_320)
        )
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(HeaderDate.parse("garbage"))
        XCTAssertNil(HeaderDate.parse(""))
        XCTAssertNil(HeaderDate.parse("32 Sep 2026 00:00:00 +0000"))
    }

    func testRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_789_113_600)
        XCTAssertEqual(HeaderDate.parse(HeaderDate.rfc5322(date, timeZone: berlin)), date)
    }
}

final class HeaderFoldingTests: XCTestCase {

    func testUnfold() {
        XCTAssertEqual(HeaderFolding.unfold("Alice\r\n <alice@example.com>"), "Alice <alice@example.com>")
        XCTAssertEqual(HeaderFolding.unfold("Alice\n\t<a@b>"), "Alice\t<a@b>")
        XCTAssertEqual(HeaderFolding.unfold("a\r\nb"), "a\r\nb")
        XCTAssertEqual(HeaderFolding.unfold("value\r\n"), "value")
    }

    func testFoldAddressListStaysWithin78() {
        let list = (0..<5).map { Mailbox(name: nil, addr: "person\($0)@averylongdomainname.example") }
        let folded = HeaderFolding.foldAddressList(list, fieldName: "To")
        XCTAssertTrue(folded.hasPrefix("To: "))
        for line in folded.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 78)
        }
        XCTAssertEqual(AddressParser.parseList(String(folded.dropFirst(4))).count, 5)
    }

    func testEmptyListsAndSingleLine() {
        XCTAssertEqual(HeaderFolding.foldAddressList([], fieldName: "Cc"), "Cc:")
        XCTAssertEqual(HeaderFolding.foldMessageIDs([], fieldName: "References"), "References:")
        XCTAssertEqual(
            HeaderFolding.foldMessageIDs(
                ["<older-id@example.com>", "<CAF=abc123@mail.example.com>"],
                fieldName: "References"
            ),
            "References: <older-id@example.com> <CAF=abc123@mail.example.com>"
        )
    }
}

final class ContentTypeParamsTests: XCTestCase {

    func testTypeAndCharset() {
        let value = ContentTypeParams.parse("text/html; charset=\"UTF-8\"")
        XCTAssertEqual(value.type, "text/html")
        XCTAssertEqual(value.param("charset"), "UTF-8")
        XCTAssertEqual(value.param("CHARSET"), "UTF-8")
    }

    func testBoundaryKeepsSpecialCharacters() {
        let value = ContentTypeParams.parse(
            "multipart/alternative; boundary=\"=_minimail_alt_7c1e3f2a9b4d4e6f\""
        )
        XCTAssertEqual(value.param("boundary"), "=_minimail_alt_7c1e3f2a9b4d4e6f")
    }

    func testCaseAndMissingSpace() {
        let value = ContentTypeParams.parse("Text/Plain;charset=iso-8859-1")
        XCTAssertEqual(value.type, "text/plain")
        XCTAssertEqual(value.param("charset"), "iso-8859-1")
    }

    func testCommentsIgnoredAndValuelessParamSkipped() {
        let value = ContentTypeParams.parse("multipart/mixed; boundary=abc (comment); x")
        XCTAssertEqual(value.param("boundary"), "abc")
        XCTAssertNil(value.param("x"))
    }

    func testEmptyHeader() {
        let value = ContentTypeParams.parse("")
        XCTAssertEqual(value.type, "")
        XCTAssertTrue(value.params.isEmpty)
    }

    func testContinuationParamsArePreserved() {
        let value = ContentTypeParams.parse(
            "attachment; filename*0*=utf-8''%C3%84nge; filename*1*=bot; filename*2=\".pdf\""
        )
        XCTAssertEqual(value.params.map(\.0), ["filename*0*", "filename*1*", "filename*2"])
    }

    func testEquality() {
        XCTAssertEqual(ContentTypeParams.parse("text/html; a=1"), ContentTypeParams.parse("text/html; a=1"))
        XCTAssertNotEqual(ContentTypeParams.parse("text/html; a=1"), ContentTypeParams.parse("text/html; a=2"))
    }
}

final class MessageIDsTests: XCTestCase {

    func testSplit() {
        XCTAssertEqual(MessageIDs.split("<a@x> junk <b@y>"), ["<a@x>", "<b@y>"])
        XCTAssertEqual(MessageIDs.split("<a@x><b@y>"), ["<a@x>", "<b@y>"])
        XCTAssertEqual(MessageIDs.split("<a@x>\r\n <b@y>"), ["<a@x>", "<b@y>"])
        XCTAssertEqual(MessageIDs.split("no ids"), [])
        XCTAssertEqual(MessageIDs.split("<>"), [])
    }

    func testNormalize() {
        XCTAssertEqual(MessageIDs.normalize(" CAF=abc@mail.example.com "), "<CAF=abc@mail.example.com>")
        XCTAssertEqual(MessageIDs.normalize("<x>"), "<x>")
        XCTAssertNil(MessageIDs.normalize("<a b@c>"))
        XCTAssertNil(MessageIDs.normalize(""))
    }

    func testGenerate() {
        let uuid = UUID(uuidString: "7C1E3F2A-9B4D-4E6F-8A10-2B3C4D5E6F70")!
        XCTAssertEqual(
            MessageIDs.generate(domain: "newtelco.de", uuid: uuid),
            "<7C1E3F2A-9B4D-4E6F-8A10-2B3C4D5E6F70@newtelco.de>"
        )
        XCTAssertTrue(MessageIDs.generate(domain: "", uuid: uuid).hasSuffix("@localhost>"))
    }

    func testReferencesChain() {
        XCTAssertEqual(
            MessageIDs.referencesChain(
                parentReferences: ["<older>"],
                parentInReplyTo: nil,
                parentMessageID: "<CAF>"
            ),
            ["<older>", "<CAF>"]
        )
        XCTAssertEqual(
            MessageIDs.referencesChain(parentReferences: [], parentInReplyTo: "<p>", parentMessageID: "<CAF>"),
            ["<p>", "<CAF>"]
        )
        XCTAssertEqual(
            MessageIDs.referencesChain(
                parentReferences: [],
                parentInReplyTo: "<p> <q>",
                parentMessageID: "<CAF>"
            ),
            ["<CAF>"]
        )
        XCTAssertEqual(
            MessageIDs.referencesChain(parentReferences: [], parentInReplyTo: nil, parentMessageID: nil),
            []
        )
        XCTAssertEqual(
            MessageIDs.referencesChain(
                parentReferences: ["<a>", "<CAF>"],
                parentInReplyTo: nil,
                parentMessageID: "<CAF>"
            ),
            ["<a>", "<CAF>"]
        )
        XCTAssertEqual(
            MessageIDs.referencesChain(
                parentReferences: [],
                parentInReplyTo: nil,
                parentMessageID: "CAF@x"
            ),
            ["<CAF@x>"]
        )
    }
}
