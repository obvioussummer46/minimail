import XCTest

@testable import MailCore

final class Base64URLTests: XCTestCase {

    func testEncodeUsesURLAlphabetWithPadding() {
        XCTAssertEqual(Base64URL.encode(Data()), "")
        XCTAssertEqual(Base64URL.encode(Data([0x66])), "Zg==")
        XCTAssertEqual(Base64URL.encode(Data([0xFB, 0xFF, 0xBF])), "-_-_")
    }

    func testDecodeAcceptsBothAlphabetsPaddedOrNot() {
        XCTAssertEqual(Base64URL.decode(""), Data())
        XCTAssertEqual(Base64URL.decode("Zg"), Data([0x66]))
        XCTAssertEqual(Base64URL.decode("Zg=="), Data([0x66]))
        XCTAssertEqual(Base64URL.decode("-_-_"), Data([0xFB, 0xFF, 0xBF]))
        XCTAssertEqual(Base64URL.decode("+/+/"), Data([0xFB, 0xFF, 0xBF]))
    }

    func testDecodeRejectsMalformedInput() {
        XCTAssertNil(Base64URL.decode("Zg=x"))
        XCTAssertNil(Base64URL.decode("Z g"))
        XCTAssertNil(Base64URL.decode("Zg==="))
        XCTAssertNil(Base64URL.decode("Zm9vYmFyX"))
    }

    func testRoundTrip() {
        let data = Data((0...255).map { UInt8($0) })
        XCTAssertEqual(Base64URL.decode(Base64URL.encode(data)), data)
    }
}

final class QuotedPrintableTests: XCTestCase {

    private func encode(_ string: String) -> String {
        String(decoding: QuotedPrintable.encode(Data(string.utf8)), as: UTF8.self)
    }

    func testDocumentedVectors() {
        XCTAssertEqual(encode("Grüße"), "Gr=C3=BC=C3=9Fe")
        XCTAssertEqual(encode("a=b"), "a=3Db")
        XCTAssertEqual(encode("trailing space "), "trailing space=20")
        XCTAssertEqual(encode("tab\tend\t"), "tab\tend=09")
        XCTAssertEqual(encode("Viele Grüße\r\nMax"), "Viele Gr=C3=BC=C3=9Fe\r\nMax")
        XCTAssertEqual(encode("-- "), "--=20")
    }

    func testSoftBreakAtSeventySix() {
        let encoded = encode(String(repeating: "x", count: 80))
        XCTAssertEqual(encoded, String(repeating: "x", count: 75) + "=\r\n" + String(repeating: "x", count: 5))
        for line in encoded.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 76)
        }
    }

    func testTokenNeverStraddlesABreak() {
        let encoded = encode(String(repeating: "ü", count: 60))
        for line in encoded.components(separatedBy: "\r\n") {
            let body = line.hasSuffix("=") ? String(line.dropLast()) : line
            XCTAssertEqual(body.count % 3, 0, "an =XX token was split across lines")
        }
    }

    func testDecodeIsTolerant() {
        func decode(_ s: String) -> String {
            String(decoding: QuotedPrintable.decode(Data(s.utf8)), as: UTF8.self)
        }
        XCTAssertEqual(decode("Gr=C3=BC=C3=9Fe"), "Grüße")
        XCTAssertEqual(decode("Gr=c3=bc=C3=9Fe"), "Grüße")
        XCTAssertEqual(decode("soft=\r\nbreak"), "softbreak")
        XCTAssertEqual(decode("soft=\nbreak"), "softbreak")
        XCTAssertEqual(decode("lone = sign"), "lone = sign")
        XCTAssertEqual(decode("trailing   \r\nnext"), "trailing\r\nnext")
        XCTAssertEqual(decode("end   "), "end")
    }

    func testRoundTripThroughDecode() {
        let original = "Viele Grüße\r\n\r\nMax Mustermann\r\n-- \r\nExample GmbH"
        let encoded = QuotedPrintable.encode(Data(original.utf8))
        XCTAssertEqual(String(decoding: QuotedPrintable.decode(encoded), as: UTF8.self), original)
    }
}

final class RFC2047Tests: XCTestCase {

    func testDecodeBAndQ() {
        XCTAssertEqual(RFC2047.decode("=?UTF-8?B?QWxpY2UgTcO8bGxlcg==?="), "Alice Müller")
        XCTAssertEqual(RFC2047.decode("=?UTF-8?Q?Alice_M=C3=BCller?="), "Alice Müller")
        XCTAssertEqual(RFC2047.decode("=?utf-8?b?w6Q=?="), "ä")
        XCTAssertEqual(RFC2047.decode("=?UTF-8?B?w6Q?="), "ä", "missing padding must still decode")
    }

    func testPlainTextAndSurroundingSpacingKept() {
        XCTAssertEqual(RFC2047.decode("plain text"), "plain text")
        XCTAssertEqual(RFC2047.decode("Re: =?UTF-8?B?QW5nZWJvdA==?="), "Re: Angebot")
    }

    func testWhitespaceBetweenAdjacentWordsIsDropped() {
        XCTAssertEqual(RFC2047.decode("=?UTF-8?B?QQ==?= =?UTF-8?B?Qg==?="), "AB")
    }

    func testSplitMultibyteSequenceAcrossWords() {
        XCTAssertEqual(RFC2047.decode("=?UTF-8?B?w6M=?==?UTF-8?B?w6Q=?="), "ãä")
    }

    func testUnknownCharsetLeftVerbatim() {
        let input = "=?x-unknown-charset?B?QQ==?="
        XCTAssertEqual(RFC2047.decode(input), input)
    }

    func testEncodeLeavesSafeASCIIAlone() {
        XCTAssertEqual(RFC2047.encodeIfNeeded("Re: Angebot", firstLineOffset: 9), "Re: Angebot")
    }

    func testEncodeProducesDocumentedWords() {
        XCTAssertEqual(
            RFC2047.encodeIfNeeded("Re: Angebot für die Erweiterung", firstLineOffset: 9),
            "=?UTF-8?B?UmU6IEFuZ2Vib3QgZsO8ciBkaWUgRXJ3ZWl0ZXJ1bmc=?="
        )
        XCTAssertEqual(
            RFC2047.encodeIfNeeded("Alice Müller", firstLineOffset: 0),
            "=?UTF-8?B?QWxpY2UgTcO8bGxlcg==?="
        )
    }

    func testEncodeThenDecodeRoundTrips() {
        let subject = String(repeating: "ÄÖÜäöüß", count: 4)
        let encoded = RFC2047.encodeIfNeeded(subject, firstLineOffset: 9)
        XCTAssertTrue(encoded.contains("\r\n "), "long subjects must fold")
        XCTAssertEqual(RFC2047.decode(encoded), subject)
        for line in encoded.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 76)
        }
    }
}

final class RFC2231Tests: XCTestCase {

    private func filename(_ header: String) -> String? {
        RFC2231.parameter(named: "filename", in: ContentTypeParams.parse(header).params)
    }

    func testPlainAndQuotedValues() {
        XCTAssertEqual(filename("attachment; filename=\"Angebot.pdf\""), "Angebot.pdf")
        XCTAssertEqual(filename("attachment; filename=Angebot.pdf"), "Angebot.pdf")
    }

    func testExtendedValue() {
        XCTAssertEqual(
            filename("attachment; filename*=UTF-8''%C3%84ngebot.pdf"),
            "Ängebot.pdf"
        )
    }

    func testContinuations() {
        XCTAssertEqual(
            filename("attachment; filename*0*=utf-8''%C3%84nge; filename*1*=bot; filename*2=\".pdf\""),
            "Ängebot.pdf"
        )
    }

    func testEncodedWordInsidePlainValue() {
        XCTAssertEqual(
            filename("attachment; filename=\"=?UTF-8?B?w4RuZ2Vib3QucGRm?=\""),
            "Ängebot.pdf"
        )
    }

    func testEncodeFilenameParams() {
        XCTAssertEqual(RFC2231.encodeFilenameParams("Angebot 2026.pdf"), "filename=\"Angebot 2026.pdf\"")
        XCTAssertEqual(
            RFC2231.encodeFilenameParams("Ängebot.pdf"),
            "filename=\"_ngebot.pdf\"; filename*=UTF-8''%C3%84ngebot.pdf"
        )
    }

    func testEncodeThenParseRoundTrips() {
        let original = "Ängebot »2026«.pdf"
        let header = "attachment; " + RFC2231.encodeFilenameParams(original)
        XCTAssertEqual(filename(header), original)
    }
}

final class CharsetsTests: XCTestCase {

    func testAliasLookup() {
        XCTAssertEqual(Charsets.encoding(forIANA: "UTF-8"), .utf8)
        XCTAssertEqual(Charsets.encoding(forIANA: " \"utf8\" "), .utf8)
        XCTAssertEqual(Charsets.encoding(forIANA: "utf-8*en"), .utf8)
        XCTAssertEqual(Charsets.encoding(forIANA: "ISO-8859-1"), .isoLatin1)
        XCTAssertEqual(Charsets.encoding(forIANA: "windows-1252"), .windowsCP1252)
        XCTAssertNil(Charsets.encoding(forIANA: "x-nonsense"))
    }

    func testDecodeFallsBackAndStripsBOM() {
        XCTAssertEqual(Charsets.decode(Data([0xC3, 0xA4]), charset: "utf-8"), "ä")
        XCTAssertEqual(Charsets.decode(Data([0xE4]), charset: "iso-8859-1"), "ä")
        XCTAssertEqual(Charsets.decode(Data([0xE4]), charset: "utf-8"), "ä", "invalid UTF-8 falls back to Latin-1")
        XCTAssertEqual(Charsets.decode(Data([0xEF, 0xBB, 0xBF, 0x61]), charset: nil), "a")
        XCTAssertEqual(Charsets.decode(Data([0xC3, 0xA4]), charset: "x-nonsense"), "ä")
    }
}
