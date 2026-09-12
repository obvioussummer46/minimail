import XCTest

@testable import MailCore

final class GmailDTOTests: XCTestCase {

    func testStringUInt64AcceptsStringAndNumber() throws {
        struct Box: Codable, Equatable { var v: StringUInt64 }
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: Data(#"{"v":"1234567"}"#.utf8)).v, 1_234_567)
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: Data(#"{"v":1234567}"#.utf8)).v, 1_234_567)
    }

    func testStringUInt64RejectsBadInput() {
        struct Box: Codable { var v: StringUInt64 }
        for json in [#"{"v":""}"#, #"{"v":"-1"}"#, #"{"v":"12a"}"#, #"{"v":true}"#, #"{"v":null}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(Box.self, from: Data(json.utf8)), json)
        }
    }

    func testStringUInt64EncodesAsString() throws {
        struct Box: Codable { var v: StringUInt64 }
        let data = try JSONEncoder().encode(Box(v: 42))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"v":"42"}"#)
    }

    func testStringInt64HandlesEpochMilliseconds() throws {
        struct Box: Codable { var v: StringInt64 }
        let box = try JSONDecoder().decode(Box.self, from: Data(#"{"v":"1757488353000"}"#.utf8))
        XCTAssertEqual(box.v.value, 1_757_488_353_000)
        XCTAssertLessThan(StringInt64(1), StringInt64(2))
    }

    func testProfileAndLabels() throws {
        let profile = try JSONDecoder().decode(
            GmailProfile.self,
            from: Data(#"{"emailAddress":"max@newtelco.de","historyId":"98765","messagesTotal":10}"#.utf8)
        )
        XCTAssertEqual(profile.emailAddress, "max@newtelco.de")
        XCTAssertEqual(profile.historyId, 98765)

        let labels = try JSONDecoder().decode(
            GmailListLabelsResponse.self,
            from: Data(#"{"labels":[{"id":"INBOX","name":"INBOX","type":"system"}]}"#.utf8)
        )
        XCTAssertEqual(labels.labels?.first?.id, "INBOX")
        XCTAssertNil(labels.labels?.first?.messagesUnread)
    }

    func testLabelWithCountsAndColour() throws {
        let json = """
            {"id":"Label_7","name":"Kunden","type":"user","messagesTotal":12,"messagesUnread":3,
             "threadsTotal":9,"threadsUnread":2,"color":{"textColor":"#ffffff","backgroundColor":"#16a765"}}
            """
        let label = try JSONDecoder().decode(GmailLabel.self, from: Data(json.utf8))
        XCTAssertEqual(label.messagesUnread, 3)
        XCTAssertEqual(label.color?.backgroundColor, "#16a765")
    }

    func testListMessagesPages() throws {
        let first = try JSONDecoder().decode(
            GmailListMessagesResponse.self,
            from: Data(#"{"messages":[{"id":"m1","threadId":"t1"}],"nextPageToken":"p2"}"#.utf8)
        )
        XCTAssertEqual(first.messages?.count, 1)
        XCTAssertEqual(first.nextPageToken, "p2")

        let last = try JSONDecoder().decode(
            GmailListMessagesResponse.self,
            from: Data(#"{"resultSizeEstimate":0}"#.utf8)
        )
        XCTAssertNil(last.messages)
    }

    func testHistoryRecord() throws {
        let json = """
            {"history":[{"id":"1001","labelsRemoved":[{"message":{"id":"m1","threadId":"t1",
             "labelIds":["INBOX"]},"labelIds":["UNREAD"]}]}],"historyId":"1002"}
            """
        let response = try JSONDecoder().decode(GmailListHistoryResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.historyId, 1002)
        XCTAssertEqual(response.history?.first?.labelsRemoved?.first?.labelIds, ["UNREAD"])
        XCTAssertEqual(response.history?.first?.labelsRemoved?.first?.message.labelIds, ["INBOX"])
    }

    func testModifyRequestOmitsNilArrays() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(GmailModifyRequest(addLabelIds: nil, removeLabelIds: ["UNREAD"]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"removeLabelIds":["UNREAD"]}"#)
    }

    func testErrorEnvelope() throws {
        let json = """
            {"error":{"code":429,"message":"Rate Limit Exceeded","status":"RESOURCE_EXHAUSTED",
             "errors":[{"reason":"rateLimitExceeded","message":"Rate Limit Exceeded"}]}}
            """
        let envelope = try JSONDecoder().decode(GmailErrorEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.error.code, 429)
        XCTAssertEqual(envelope.primaryReason, "rateLimitExceeded")
        XCTAssertThrowsError(try JSONDecoder().decode(GmailErrorEnvelope.self, from: Data("{}".utf8)))
    }

    func testHeaderLookupIsCaseInsensitiveAndUnfolds() {
        let part = GmailPart(headers: [
            GmailHeader(name: "Message-Id", value: "  <abc@x>  "),
            GmailHeader(name: "References", value: "<a@x>\r\n <b@x>"),
        ])
        XCTAssertEqual(part.header("Message-ID"), "<abc@x>")
        XCTAssertEqual(part.header("references"), "<a@x> <b@x>")
        XCTAssertNil(part.header("Subject"))
    }

    func testMetadataHeaderList() {
        XCTAssertEqual(gmailMetadataHeaders.first, "From")
        XCTAssertEqual(gmailMetadataHeaders.count, 9)
        XCTAssertTrue(gmailMetadataHeaders.contains("References"))
    }
}

final class SnippetEntitiesTests: XCTestCase {

    func testDecodesNamedAndNumericEntitiesOnce() {
        XCTAssertEqual(SnippetEntities.decode("Hi Bob &amp; team, it&#39;s done."), "Hi Bob & team, it's done.")
        XCTAssertEqual(SnippetEntities.decode("&quot;Quoted&quot; &lt;b&gt;"), "\"Quoted\" <b>")
        XCTAssertEqual(SnippetEntities.decode("&amp;lt;"), "&lt;")
        XCTAssertEqual(SnippetEntities.decode("caf&#233;"), "café")
        XCTAssertEqual(SnippetEntities.decode("&#x1F600;"), "😀")
        XCTAssertEqual(SnippetEntities.decode("a&nbsp;b"), "a b")
    }

    func testLeavesUnknownAndInvalidAlone() {
        XCTAssertEqual(SnippetEntities.decode("&unknown; &"), "&unknown; &")
        XCTAssertEqual(SnippetEntities.decode("&#99999999;"), "&#99999999;")
        XCTAssertEqual(SnippetEntities.decode("no entities"), "no entities")
    }
}

final class MessageParserTests: XCTestCase {

    private func b64(_ s: String) -> String { Base64URL.encode(Data(s.utf8)) }

    private func header(_ name: String, _ value: String) -> GmailHeader {
        GmailHeader(name: name, value: value)
    }

    func testMetadataOnlyMessage() {
        let message = GmailMessage(
            id: "m1",
            threadId: "t1",
            labelIds: ["INBOX", "UNREAD"],
            snippet: "Hi Bob &amp; team",
            historyId: 1001,
            internalDate: 1_757_488_353_000,
            payload: GmailPart(
                mimeType: "multipart/alternative",
                headers: [
                    header("From", "=?UTF-8?B?QWxpY2UgTcO8bGxlcg==?= <alice@example.com>"),
                    header("To", "Max <max@newtelco.de>, bob@example.com"),
                    header("Cc", "carol@partner.example"),
                    header("Reply-To", "sales@example.com"),
                    header("Subject", "Re:   Angebot\r\n für die Erweiterung"),
                    header("Message-Id", "<CAF=abc@mail.example.com>"),
                    header("In-Reply-To", "<p1@x> <p2@x>"),
                    header("References", "<older@x> <p1@x>"),
                ]
            )
        )
        let parsed = MessageParser.parse(message)

        XCTAssertEqual(parsed.threadId, "t1")
        XCTAssertEqual(parsed.historyId, 1001)
        XCTAssertEqual(parsed.internalDate, 1_757_488_353_000)
        XCTAssertEqual(parsed.labelIds, ["INBOX", "UNREAD"])
        XCTAssertEqual(parsed.snippet, "Hi Bob & team")
        XCTAssertEqual(parsed.headers.from, Mailbox(name: "Alice Müller", addr: "alice@example.com"))
        XCTAssertEqual(parsed.headers.to.count, 2)
        XCTAssertEqual(parsed.headers.cc.map(\.addr), ["carol@partner.example"])
        XCTAssertEqual(parsed.headers.replyTo.map(\.addr), ["sales@example.com"])
        XCTAssertEqual(parsed.headers.subject, "Re: Angebot für die Erweiterung")
        XCTAssertEqual(parsed.headers.messageID, "<CAF=abc@mail.example.com>")
        XCTAssertEqual(parsed.headers.inReplyTo, "<p1@x>", "only the first token is kept")
        XCTAssertEqual(parsed.headers.references, ["<older@x>", "<p1@x>"])
        XCTAssertEqual(parsed.topMimeType, "multipart/alternative")
        XCTAssertNil(parsed.body, "metadata format carries no body")
        XCTAssertTrue(parsed.attachments.isEmpty)
    }

    func testMinimalMessageAndMissingFields() {
        let parsed = MessageParser.parse(GmailMessage(id: "m9"))
        XCTAssertEqual(parsed.threadId, "m9", "threadId falls back to id")
        XCTAssertEqual(parsed.historyId, 0)
        XCTAssertEqual(parsed.internalDate, 0)
        XCTAssertEqual(parsed.labelIds, [])
        XCTAssertEqual(parsed.snippet, "")
        XCTAssertEqual(parsed.headers.subject, "")
        XCTAssertNil(parsed.headers.from)
        XCTAssertNil(parsed.body)
    }

    func testBareTextPlainPayload() {
        let message = GmailMessage(
            id: "a",
            payload: GmailPart(
                partId: "",
                mimeType: "text/plain",
                headers: [header("Content-Type", "text/plain")],
                body: GmailPartBody(size: 5, data: b64("Hallo"))
            )
        )
        let parsed = MessageParser.parse(message)
        XCTAssertEqual(parsed.body?.text, "Hallo")
        XCTAssertNil(parsed.body?.html)
        XCTAssertTrue(parsed.attachments.isEmpty)
    }

    func testMultipartAlternativePrefersFirstOfEachType() {
        let message = GmailMessage(
            id: "b",
            payload: GmailPart(
                mimeType: "multipart/alternative",
                parts: [
                    GmailPart(
                        partId: "0",
                        mimeType: "text/plain",
                        headers: [header("Content-Type", "text/plain; charset=\"iso-8859-1\"")],
                        body: GmailPartBody(data: Base64URL.encode(Data([0x47, 0x72, 0xFC, 0xDF, 0x65])))
                    ),
                    GmailPart(
                        partId: "1",
                        mimeType: "text/html",
                        headers: [header("Content-Type", "text/html; charset=\"UTF-8\"")],
                        body: GmailPartBody(data: b64("<p>Grüße</p>"))
                    ),
                    GmailPart(
                        partId: "2",
                        mimeType: "text/html",
                        body: GmailPartBody(data: b64("<p>second</p>"))
                    ),
                ]
            )
        )
        let parsed = MessageParser.parse(message)
        XCTAssertEqual(parsed.body?.text, "Grüße", "latin-1 decoded via the part charset")
        XCTAssertEqual(parsed.body?.html, "<p>Grüße</p>", "the first html part wins")
    }

    func testMixedWithAttachments() {
        let message = GmailMessage(
            id: "c",
            payload: GmailPart(
                mimeType: "multipart/mixed",
                parts: [
                    GmailPart(
                        partId: "0",
                        mimeType: "text/plain",
                        body: GmailPartBody(data: b64("see attached"))
                    ),
                    GmailPart(
                        partId: "1",
                        mimeType: "application/pdf",
                        filename: "Angebot.pdf",
                        body: GmailPartBody(attachmentId: "ANGI", size: 90210)
                    ),
                    GmailPart(
                        partId: "2",
                        mimeType: "text/plain",
                        filename: "notes.txt",
                        body: GmailPartBody(attachmentId: "NOTES", size: 12)
                    ),
                ]
            )
        )
        let parsed = MessageParser.parse(message)
        XCTAssertEqual(parsed.body?.text, "see attached")
        XCTAssertEqual(parsed.attachments.map(\.filename), ["Angebot.pdf", "notes.txt"])
        XCTAssertEqual(parsed.attachments.first?.size, 90210)
        XCTAssertEqual(parsed.attachments.first?.attachmentId, "ANGI")
        XCTAssertTrue(parsed.body?.deferredTextParts.isEmpty ?? false)
    }

    func testInlineImageKeepsContentID() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let message = GmailMessage(
            id: "d",
            payload: GmailPart(
                mimeType: "multipart/related",
                parts: [
                    GmailPart(partId: "0", mimeType: "text/html", body: GmailPartBody(data: b64("<img>"))),
                    GmailPart(
                        partId: "1",
                        mimeType: "image/png",
                        filename: "logo.png",
                        headers: [header("Content-ID", " <ii_logo> ")],
                        body: GmailPartBody(size: 4, data: Base64URL.encode(png))
                    ),
                ]
            )
        )
        let parsed = MessageParser.parse(message)
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments.first?.contentId, "ii_logo")
        XCTAssertEqual(parsed.attachments.first?.inlineData, png)
        XCTAssertNil(parsed.attachments.first?.attachmentId)
    }

    func testTextBodyDeliveredByAttachmentIdIsDeferred() {
        let message = GmailMessage(
            id: "h",
            payload: GmailPart(
                mimeType: "multipart/alternative",
                parts: [
                    GmailPart(partId: "0", mimeType: "text/plain", body: GmailPartBody(data: b64("short"))),
                    GmailPart(
                        partId: "1",
                        mimeType: "text/html",
                        body: GmailPartBody(attachmentId: "BIGHTML", size: 3_000_000)
                    ),
                ]
            )
        )
        let parsed = MessageParser.parse(message)
        XCTAssertEqual(parsed.body?.text, "short")
        XCTAssertNil(parsed.body?.html)
        XCTAssertEqual(parsed.body?.deferredTextParts.count, 1)
        XCTAssertEqual(parsed.body?.deferredTextParts.first?.attachmentId, "BIGHTML")
        XCTAssertEqual(parsed.body?.deferredTextParts.first?.filename, "")
        XCTAssertTrue(parsed.attachments.isEmpty)
    }

    func testMessageRFC822IsNotRecursed() {
        let message = GmailMessage(
            id: "g",
            payload: GmailPart(
                mimeType: "multipart/report",
                parts: [
                    GmailPart(partId: "0", mimeType: "text/plain", body: GmailPartBody(data: b64("failed"))),
                    GmailPart(partId: "1", mimeType: "message/delivery-status"),
                    GmailPart(
                        partId: "2",
                        mimeType: "message/rfc822",
                        parts: [
                            GmailPart(
                                partId: "2.0",
                                mimeType: "text/plain",
                                body: GmailPartBody(data: b64("original"))
                            )
                        ]
                    ),
                ]
            )
        )
        let parsed = MessageParser.parse(message)
        XCTAssertEqual(parsed.body?.text, "failed", "the embedded original must not replace the body")
        XCTAssertTrue(parsed.attachments.isEmpty)
    }

    func testFilenameFallbacks() {
        let message = GmailMessage(
            id: "f",
            payload: GmailPart(
                mimeType: "multipart/mixed",
                parts: [
                    GmailPart(partId: "0", mimeType: "text/plain", body: GmailPartBody(data: b64("x"))),
                    GmailPart(
                        partId: "1",
                        mimeType: "application/pdf",
                        headers: [
                            header("Content-Disposition", "attachment; filename*=UTF-8''%C3%84ngebot.pdf")
                        ],
                        body: GmailPartBody(attachmentId: "A1", size: 10)
                    ),
                    GmailPart(
                        partId: "2",
                        mimeType: "application/octet-stream",
                        headers: [header("Content-Type", "application/octet-stream; name=\"data.bin\"")],
                        body: GmailPartBody(attachmentId: "A2", size: 10)
                    ),
                    GmailPart(
                        partId: "3",
                        mimeType: "application/zip",
                        body: GmailPartBody(attachmentId: "A3", size: 10)
                    ),
                ]
            )
        )
        let parsed = MessageParser.parse(message)
        XCTAssertEqual(parsed.attachments.map(\.filename), ["Ängebot.pdf", "data.bin", "attachment-3"])
    }

    func testDecodeTextHandlesMissingAndBadData() {
        XCTAssertNil(MessageParser.decodeText(GmailPart(mimeType: "text/plain")))
        XCTAssertNil(
            MessageParser.decodeText(
                GmailPart(mimeType: "text/plain", body: GmailPartBody(data: "not valid!"))
            )
        )
        XCTAssertEqual(
            MessageParser.decodeText(GmailPart(mimeType: "text/plain", body: GmailPartBody(data: ""))),
            nil,
            "an empty data string means the part carried nothing"
        )
        XCTAssertEqual(
            MessageParser.decodeText(bytes: Data("a\r\nb\rc".utf8), charset: nil),
            "a\nb\nc"
        )
    }

    func testEmptyMessageIsTreatedAsMetadataOnly() {
        let message = GmailMessage(
            id: "e",
            payload: GmailPart(mimeType: "text/plain", body: GmailPartBody(size: 0))
        )
        XCTAssertNil(MessageParser.parse(message).body)
    }
}

final class BatchCodecTests: XCTestCase {

    func testEncodeGetOnly() {
        let data = BatchCodec.encode(
            [BatchCall(id: "m1", method: "GET", path: "/gmail/v1/users/me/messages/m1?format=metadata")],
            boundary: "B"
        )
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "--B\r\nContent-Type: application/http\r\nContent-ID: <m1>\r\n\r\n"
                + "GET /gmail/v1/users/me/messages/m1?format=metadata\r\n\r\n--B--\r\n"
        )
    }

    func testEncodePostWithJSON() {
        let data = BatchCodec.encode(
            [
                BatchCall(
                    id: "t1",
                    method: "POST",
                    path: "/gmail/v1/users/me/threads/t1/modify",
                    jsonBody: Data(#"{"removeLabelIds":["UNREAD"]}"#.utf8)
                )
            ],
            boundary: "B"
        )
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "--B\r\nContent-Type: application/http\r\nContent-ID: <t1>\r\n\r\n"
                + "POST /gmail/v1/users/me/threads/t1/modify\r\nContent-Type: application/json\r\n\r\n"
                + #"{"removeLabelIds":["UNREAD"]}"# + "\r\n\r\n--B--\r\n"
        )
    }

    func testEncodeEmptyCallList() {
        XCTAssertEqual(String(decoding: BatchCodec.encode([], boundary: "B"), as: UTF8.self), "--B--\r\n")
    }

    func testBoundaryExtraction() {
        XCTAssertEqual(BatchCodec.boundary(fromContentType: "multipart/mixed; boundary=batch_abc"), "batch_abc")
        XCTAssertEqual(
            BatchCodec.boundary(fromContentType: "multipart/mixed; boundary=\"batch_abc\"; charset=UTF-8"),
            "batch_abc"
        )
        XCTAssertNil(BatchCodec.boundary(fromContentType: "application/json; charset=UTF-8"))
        XCTAssertNil(BatchCodec.boundary(fromContentType: "multipart/mixed"))
    }

    private func response(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\r\n").utf8)
    }

    func testDecodeTwoParts() throws {
        let body = response([
            "--B",
            "Content-Type: application/http",
            "Content-ID: <response-m1>",
            "",
            "HTTP/1.1 200 OK",
            "Content-Type: application/json",
            "",
            #"{"id":"m1"}"#,
            "--B",
            "Content-Type: application/http",
            "Content-ID: <response-m2>",
            "",
            "HTTP/1.1 404 Not Found",
            "Content-Type: application/json",
            "",
            #"{"error":{"code":404}}"#,
            "--B--",
            "",
        ])
        let parts = try BatchCodec.decode(body: body, boundary: "B")
        XCTAssertEqual(parts.map(\.id), ["m1", "m2"])
        XCTAssertEqual(parts.map(\.status), [200, 404])
        XCTAssertEqual(String(decoding: parts[0].body, as: UTF8.self), #"{"id":"m1"}"#)
    }

    func testDecodeHeaderOnlyPart() throws {
        let body = response([
            "--B",
            "Content-ID: <response-t1>",
            "",
            "HTTP/1.1 204 No Content",
            "",
            "--B--",
            "",
        ])
        let parts = try BatchCodec.decode(body: body, boundary: "B")
        XCTAssertEqual(parts.first?.status, 204)
        XCTAssertTrue(parts.first?.body.isEmpty ?? false)
    }

    func testDecodeSkipsPreambleAndAcceptsPlainContentID() throws {
        let body = response([
            "ignored preamble",
            "--B",
            "Content-ID: <m1>",
            "",
            "HTTP/1.1 200 OK",
            "",
            "body",
            "--B--",
            "",
        ])
        let parts = try BatchCodec.decode(body: body, boundary: "B")
        XCTAssertEqual(parts.first?.id, "m1")
    }

    func testDecodeErrors() {
        XCTAssertThrowsError(try BatchCodec.decode(body: Data("<html>oops</html>".utf8), boundary: "B")) {
            XCTAssertEqual($0 as? BatchCodecError, .noDelimiter)
        }
        XCTAssertThrowsError(
            try BatchCodec.decode(body: response(["--B--", ""]), boundary: "B")
        ) {
            XCTAssertEqual($0 as? BatchCodecError, .noParts)
        }
        let noContentID = response([
            "--B", "Content-Type: application/http", "", "HTTP/1.1 200 OK", "", "x", "--B--", "",
        ])
        XCTAssertThrowsError(try BatchCodec.decode(body: noContentID, boundary: "B")) {
            XCTAssertEqual($0 as? BatchCodecError, .missingContentID(index: 0))
        }
        let badStatus = response(["--B", "Content-ID: <m1>", "", "NOT A STATUS", "", "x", "--B--", ""])
        XCTAssertThrowsError(try BatchCodec.decode(body: badStatus, boundary: "B")) {
            XCTAssertEqual($0 as? BatchCodecError, .badStatusLine(index: 0))
        }
    }

    func testDecodeRejectsLFOnlyInput() {
        let lfOnly = Data("--B\nContent-ID: <m1>\n\nHTTP/1.1 200 OK\n\nx\n--B--\n".utf8)
        XCTAssertThrowsError(try BatchCodec.decode(body: lfOnly, boundary: "B")) {
            XCTAssertEqual($0 as? BatchCodecError, .noDelimiter)
        }
    }
}
