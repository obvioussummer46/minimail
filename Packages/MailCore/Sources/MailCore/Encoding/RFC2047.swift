import Foundation

/// RFC 2047 encoded-words, the `=?UTF-8?B?…?=` form seen in `Subject` and display names.
public enum RFC2047 {

    private struct Word {
        var charset: String
        var isBase64: Bool
        var text: String
        var endIndex: Int
    }

    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")
    private static let cr = UInt8(ascii: "\r")
    private static let lf = UInt8(ascii: "\n")

    /// Decodes every encoded-word. Whitespace between two adjacent words is dropped, the decoded bytes of
    /// adjacent same-charset words are joined before charset decoding so a split multi-byte sequence survives,
    /// and a word with an unknown charset or undecodable payload is copied through verbatim.
    public static func decode(_ headerValue: String) -> String {
        let bytes = Array(headerValue.utf8)
        var result: [UInt8] = []
        var pendingBytes: [UInt8] = []
        var pendingCharset: String?
        var whitespace: [UInt8] = []
        var lastWasWord = false
        var index = 0

        func flushPending() {
            guard !pendingBytes.isEmpty else { return }
            result += Array(Charsets.decode(Data(pendingBytes), charset: pendingCharset).utf8)
            pendingBytes = []
        }

        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "="), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "?"),
                let word = parseEncodedWord(bytes, at: index)
            {
                let encoding = Charsets.encoding(forIANA: word.charset)
                let decodedBytes = word.isBase64 ? Base64URL.decode(word.text) : decodeQ(word.text)

                guard encoding != nil, let decodedBytes else {
                    flushPending()
                    result += whitespace
                    whitespace = []
                    result += bytes[index..<word.endIndex]
                    lastWasWord = false
                    index = word.endIndex
                    continue
                }

                if lastWasWord {
                    whitespace = []
                } else {
                    flushPending()
                    result += whitespace
                    whitespace = []
                }
                let lowered = word.charset.lowercased()
                if pendingCharset != lowered {
                    flushPending()
                    pendingCharset = lowered
                }
                pendingBytes += Array(decodedBytes)
                lastWasWord = true
                index = word.endIndex
                continue
            }

            let byte = bytes[index]
            if byte == space || byte == tab || byte == cr || byte == lf {
                whitespace.append(byte)
                index += 1
                continue
            }

            flushPending()
            result += whitespace
            whitespace = []
            result.append(byte)
            lastWasWord = false
            index += 1
        }

        flushPending()
        result += whitespace
        return String(decoding: result, as: UTF8.self)
    }

    /// Returns `text` unchanged when it is safe ASCII, otherwise UTF-8 base64 encoded-words joined by CRLF SP.
    /// `firstLineOffset` is how many characters already sit on the line, so `Subject: ` passes 9.
    public static func encodeIfNeeded(_ text: String, firstLineOffset: Int) -> String {
        let safe =
            text.unicodeScalars.allSatisfy { $0.value <= 0x7E && ($0.value >= 0x20 || $0.value == 0x09) }
            && text.count <= 900
        if safe { return text }

        let firstLimit = min(45, max(3, ((76 - firstLineOffset - 12) / 4) * 3))
        let laterLimit = 45

        var chunks: [[UInt8]] = []
        var current: [UInt8] = []
        var limit = firstLimit
        for scalar in text.unicodeScalars {
            let encoded = Array(String(scalar).utf8)
            if !current.isEmpty && current.count + encoded.count > limit {
                chunks.append(current)
                current = []
                limit = laterLimit
            }
            current += encoded
        }
        if !current.isEmpty { chunks.append(current) }

        return chunks
            .map { "=?UTF-8?B?" + Data($0).base64EncodedString() + "?=" }
            .joined(separator: "\r\n ")
    }

    /// `=?charset[*lang]?B|Q?text?=`. Fails when a piece is empty, a piece holds `?` or a space, or there is
    /// no closing `?=`.
    private static func parseEncodedWord(_ bytes: [UInt8], at start: Int) -> Word? {
        var index = start + 2
        var charset: [UInt8] = []
        while index < bytes.count, bytes[index] != UInt8(ascii: "?") {
            if bytes[index] == space || bytes[index] == tab { return nil }
            charset.append(bytes[index])
            index += 1
        }
        guard index < bytes.count, !charset.isEmpty else { return nil }
        index += 1

        guard index < bytes.count else { return nil }
        let encodingByte = bytes[index]
        let isBase64: Bool
        switch encodingByte {
        case UInt8(ascii: "B"), UInt8(ascii: "b"): isBase64 = true
        case UInt8(ascii: "Q"), UInt8(ascii: "q"): isBase64 = false
        default: return nil
        }
        index += 1
        guard index < bytes.count, bytes[index] == UInt8(ascii: "?") else { return nil }
        index += 1

        var text: [UInt8] = []
        while index < bytes.count, bytes[index] != UInt8(ascii: "?") {
            if bytes[index] == space || bytes[index] == tab { return nil }
            text.append(bytes[index])
            index += 1
        }
        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "?"),
            bytes[index + 1] == UInt8(ascii: "="), !text.isEmpty
        else { return nil }

        var charsetName = String(decoding: charset, as: UTF8.self)
        if let star = charsetName.firstIndex(of: "*") { charsetName = String(charsetName[..<star]) }
        guard !charsetName.isEmpty else { return nil }

        return Word(
            charset: charsetName,
            isBase64: isBase64,
            text: String(decoding: text, as: UTF8.self),
            endIndex: index + 2
        )
    }

    /// Q encoding: `_` is a space, `=XX` in either hex case is one octet, a lone `=` stays literal.
    private static func decodeQ(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "_") {
                out.append(space)
                index += 1
            } else if byte == UInt8(ascii: "="), index + 2 < bytes.count,
                let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2])
            {
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(byte)
                index += 1
            }
        }
        return Data(out)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}
