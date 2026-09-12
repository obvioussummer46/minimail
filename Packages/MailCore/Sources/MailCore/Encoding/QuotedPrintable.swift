import Foundation

/// RFC 2045 §6.7 quoted-printable, used for the text parts of outgoing mail.
public enum QuotedPrintable {

    private static let hex = Array("0123456789ABCDEF".utf8)
    private static let cr = UInt8(ascii: "\r")
    private static let lf = UInt8(ascii: "\n")
    private static let equals = UInt8(ascii: "=")
    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")

    /// Precondition, not checked: `utf8` already uses CRLF line breaks. `MIMEBuilder` normalises first.
    ///
    /// Octets outside 33...60 and 62...126 become `=XX` with uppercase hex, as does `=` itself. Space and tab
    /// stay literal except as the last octet of a line. Encoded lines stay within 76 characters including the
    /// soft-break `=`, and a three-character token never straddles a break.
    public static func encode(_ utf8: Data) -> Data {
        let lines = splitCRLF(Array(utf8))
        var out: [UInt8] = []

        for (lineIndex, line) in lines.enumerated() {
            let isFinalEmpty = lineIndex == lines.count - 1 && line.isEmpty
            if isFinalEmpty { break }

            var current: [UInt8] = []
            for (byteIndex, byte) in line.enumerated() {
                let isLast = byteIndex == line.count - 1
                let literal =
                    (33...60).contains(byte)
                    || (62...126).contains(byte)
                    || ((byte == space || byte == tab) && !isLast)
                let token: [UInt8] =
                    literal ? [byte] : [equals, hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
                if current.count + token.count > 75 {
                    out += current
                    out.append(equals)
                    out += [cr, lf]
                    current = []
                }
                current += token
            }
            out += current
            if lineIndex < lines.count - 1 { out += [cr, lf] }
        }
        return Data(out)
    }

    /// Tolerant decoder that never fails. Soft breaks disappear, `=XX` in either hex case becomes its octet,
    /// a lone `=` stays literal, and whitespace before a line break or at the end of input is dropped.
    public static func decode(_ data: Data) -> Data {
        let bytes = Array(data)
        var out: [UInt8] = []
        var pendingWhitespace: [UInt8] = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]

            if byte == space || byte == tab {
                pendingWhitespace.append(byte)
                index += 1
                continue
            }
            if byte == cr || byte == lf {
                pendingWhitespace = []
                out.append(byte)
                index += 1
                continue
            }

            out += pendingWhitespace
            pendingWhitespace = []

            guard byte == equals else {
                out.append(byte)
                index += 1
                continue
            }

            if index + 2 < bytes.count, let high = hexValue(bytes[index + 1]),
                let low = hexValue(bytes[index + 2])
            {
                out.append(high << 4 | low)
                index += 3
            } else if index + 2 < bytes.count, bytes[index + 1] == cr, bytes[index + 2] == lf {
                index += 3
            } else if index + 1 < bytes.count, bytes[index + 1] == lf {
                index += 2
            } else {
                out.append(equals)
                index += 1
            }
        }
        return Data(out)
    }

    /// Splits on CRLF, keeping a trailing empty element when the input ends with a break.
    private static func splitCRLF(_ bytes: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var current: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == cr, index + 1 < bytes.count, bytes[index + 1] == lf {
                lines.append(current)
                current = []
                index += 2
            } else {
                current.append(bytes[index])
                index += 1
            }
        }
        lines.append(current)
        return lines
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
