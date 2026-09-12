import XCTest

@testable import MailCore

final class BoundaryGeneratorTests: XCTestCase {

    func testRandomBoundariesDifferAndAreWellFormed() {
        let first = BoundaryGenerator.random.boundary(kind: "alt")
        let second = BoundaryGenerator.random.boundary(kind: "alt")
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("=_minimail_alt_"))
        XCTAssertEqual(first.count, "=_minimail_alt_".count + 16)
        XCTAssertTrue(first.dropFirst("=_minimail_alt_".count).allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testFixedBoundaries() {
        let generator = BoundaryGenerator.fixed(alt: "ALT", mixed: "MIXED")
        XCTAssertEqual(generator.boundary(kind: "alt"), "ALT")
        XCTAssertEqual(generator.boundary(kind: "mixed"), "MIXED")
        XCTAssertEqual(generator.boundary(kind: "other"), "=_minimail_other_0000000000000000")
    }
}

final class MIMEBuilderTests: XCTestCase {

    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private let boundaries = BoundaryGenerator.fixed(
        alt: "=_minimail_alt_7c1e3f2a9b4d4e6f",
        mixed: "=_minimail_mixed_0b1c2d3e4f5a6b7c"
    )

    private func reply(attachments: [OutgoingAttachment] = []) -> OutgoingMessage {
        OutgoingMessage(
            from: Mailbox(name: "Max Mustermann", addr: "max.mustermann@example.com"),
            to: [
                Mailbox(name: "Alice Müller", addr: "alice@example.com"),
                Mailbox(name: nil, addr: "bob@example.com"),
            ],
            cc: [Mailbox(name: "Carol Chen", addr: "carol@partner.example")],
            subject: "Re: Angebot für die Erweiterung",
            date: Date(timeIntervalSince1970: 1_789_113_600),
            timeZone: berlin,
            messageID: "<7C1E3F2A-9B4D-4E6F-8A10-2B3C4D5E6F70@example.com>",
            inReplyTo: "<CAF=abc123@mail.example.com>",
            references: ["<older-id@example.com>", "<CAF=abc123@mail.example.com>"],
            textBody: "Hallo Alice,\n\nja.\n\nViele Grüße\nMax",
            htmlBody: "<html><head><meta charset=\"utf-8\"></head><body><div>Hallo Alice,</div></body></html>",
            attachments: attachments
        )
    }

    private func build(_ message: OutgoingMessage) -> String {
        String(decoding: MIMEBuilder.build(message, boundaries: boundaries), as: UTF8.self)
    }

    func testHeaderOrderAndValues() {
        let output = build(reply())
        let headerBlock = output.components(separatedBy: "\r\n\r\n")[0]
        let fields = headerBlock.components(separatedBy: "\r\n")
            .filter { !$0.hasPrefix(" ") }
            .map { String($0.prefix(while: { $0 != ":" })) }
        XCTAssertEqual(
            fields,
            [
                "From", "To", "Cc", "Subject", "Date", "Message-ID", "In-Reply-To", "References",
                "MIME-Version", "Content-Type",
            ]
        )
        XCTAssertTrue(output.contains("From: Max Mustermann <max.mustermann@example.com>\r\n"))
        XCTAssertTrue(output.contains("Date: Fri, 11 Sep 2026 10:00:00 +0200\r\n"))
        XCTAssertTrue(output.contains("In-Reply-To: <CAF=abc123@mail.example.com>\r\n"))
        XCTAssertTrue(
            output.contains("Subject: =?UTF-8?B?UmU6IEFuZ2Vib3QgZsO8ciBkaWUgRXJ3ZWl0ZXJ1bmc=?=\r\n")
        )
    }

    func testOmitsEmptyCcAndInReplyTo() {
        var message = reply()
        message.cc = []
        message.inReplyTo = nil
        let output = build(message)
        XCTAssertFalse(output.contains("\r\nCc:"))
        XCTAssertFalse(output.contains("\r\nIn-Reply-To:"))
    }

    func testAlternativeStructureWithoutAttachments() {
        let output = build(reply())
        XCTAssertTrue(
            output.contains(
                "Content-Type: multipart/alternative; boundary=\"=_minimail_alt_7c1e3f2a9b4d4e6f\"\r\n"
            )
        )
        XCTAssertTrue(output.contains("Content-Type: text/plain; charset=\"UTF-8\"\r\n"))
        XCTAssertTrue(output.contains("Content-Type: text/html; charset=\"UTF-8\"\r\n"))
        XCTAssertEqual(output.components(separatedBy: "Content-Transfer-Encoding: quoted-printable").count - 1, 2)
        XCTAssertTrue(output.hasSuffix("--=_minimail_alt_7c1e3f2a9b4d4e6f--\r\n"))
        XCTAssertEqual(output.components(separatedBy: "MIME-Version: 1.0").count - 1, 1)
    }

    func testMixedStructureWithAttachment() {
        let pdf = OutgoingAttachment(
            filename: "Angebot-2026-09.pdf",
            mimeType: "application/pdf",
            data: Data(repeating: 0x25, count: 200)
        )
        let output = build(reply(attachments: [pdf]))
        XCTAssertTrue(
            output.contains(
                "Content-Type: multipart/mixed; boundary=\"=_minimail_mixed_0b1c2d3e4f5a6b7c\"\r\n"
            )
        )
        XCTAssertTrue(output.contains("Content-Type: application/pdf; name=\"Angebot-2026-09.pdf\"\r\n"))
        XCTAssertTrue(
            output.contains(
                "Content-Disposition: attachment; filename=\"Angebot-2026-09.pdf\"; size=200\r\n"
            )
        )
        XCTAssertTrue(output.contains("Content-Transfer-Encoding: base64\r\n"))
        XCTAssertTrue(output.hasSuffix("--=_minimail_mixed_0b1c2d3e4f5a6b7c--\r\n"))
    }

    func testNonASCIIAttachmentNameUsesBothParameterForms() {
        let attachment = OutgoingAttachment(
            filename: "Ängebot.pdf",
            mimeType: "application/pdf",
            data: Data([0x25])
        )
        let output = build(reply(attachments: [attachment]))
        XCTAssertTrue(output.contains("name=\"_ngebot.pdf\""))
        XCTAssertTrue(output.contains("filename=\"_ngebot.pdf\"; filename*=UTF-8''%C3%84ngebot.pdf"))
    }

    func testUnknownMimeTypeAndUnsafeFilenameAreSanitized() {
        let attachment = OutgoingAttachment(
            filename: "../etc/pa\"sswd",
            mimeType: "not a mime type",
            data: Data([0x00])
        )
        let output = build(reply(attachments: [attachment]))
        XCTAssertTrue(output.contains("Content-Type: application/octet-stream;"))
        XCTAssertFalse(output.contains("../etc"))
    }

    func testBase64LinesWrapAtSeventySix() {
        let attachment = OutgoingAttachment(
            filename: "big.bin",
            mimeType: "application/octet-stream",
            data: Data(repeating: 0xAB, count: 1000)
        )
        let output = build(reply(attachments: [attachment]))
        guard let range = output.range(of: "Content-Transfer-Encoding: base64\r\n\r\n") else {
            return XCTFail("no base64 part")
        }
        let payload = output[range.upperBound...]
            .components(separatedBy: "\r\n--=_minimail_mixed")[0]
        for line in payload.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 76)
        }
    }

    func testBodyLineBreaksAreNormalisedToCRLF() {
        var message = reply()
        message.textBody = "one\rtwo\r\nthree\nfour"
        let output = build(message)
        let encoded = QuotedPrintable.encode(Data("one\r\ntwo\r\nthree\r\nfour\r\n".utf8))
        XCTAssertTrue(output.contains(String(decoding: encoded, as: UTF8.self)))
    }

    func testEveryLineIsWithinTheHardLimit() {
        let output = build(reply())
        for line in output.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 998)
        }
    }

    func testDeterministicForFixedBoundaries() {
        XCTAssertEqual(
            MIMEBuilder.build(reply(), boundaries: boundaries),
            MIMEBuilder.build(reply(), boundaries: boundaries)
        )
    }

    func testBodiesSurviveTheRoundTrip() {
        let message = reply()
        let output = build(message)
        guard let start = output.range(of: "Content-Transfer-Encoding: quoted-printable\r\n\r\n") else {
            return XCTFail("no text part")
        }
        let encoded = output[start.upperBound...].components(separatedBy: "\r\n--=_minimail_alt")[0]
        let decoded = String(decoding: QuotedPrintable.decode(Data(encoded.utf8)), as: UTF8.self)
        XCTAssertEqual(decoded, "Hallo Alice,\r\n\r\nja.\r\n\r\nViele Grüße\r\nMax\r\n")
    }
}
