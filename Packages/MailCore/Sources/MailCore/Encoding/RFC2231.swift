import Foundation

/// RFC 2231 parameter continuations and charset-tagged values, which is how attachment filenames arrive.
public enum RFC2231 {

    /// Looks `named` up case-insensitively. Precedence: the starred extended form, then numbered
    /// continuations, then the plain value with any encoded-word decoded.
    public static func parameter(named: String, in params: [(String, String)]) -> String? {
        let target = named.lowercased()

        if let pair = params.first(where: { $0.0.lowercased() == target + "*" }) {
            return decodeExtended(pair.1)
        }

        var segments: [(Int, Bool, String)] = []
        for (name, value) in params {
            let lowered = name.lowercased()
            guard lowered.hasPrefix(target + "*") else { continue }
            var rest = String(lowered.dropFirst(target.count + 1))
            let starred = rest.hasSuffix("*")
            if starred { rest.removeLast() }
            guard !rest.isEmpty, let number = Int(rest) else { continue }
            segments.append((number, starred, value))
        }

        if !segments.isEmpty {
            segments.sort { $0.0 < $1.0 }
            var bytes: [UInt8] = []
            var charset = "utf-8"
            for (number, starred, value) in segments {
                var payload = value
                if number == 0 && starred {
                    let parts = splitExtended(value)
                    if let named = parts.charset, !named.isEmpty { charset = named }
                    payload = parts.payload
                }
                bytes += starred ? percentDecode(payload) : Array(payload.utf8)
            }
            return Charsets.decode(Data(bytes), charset: charset)
        }

        if let pair = params.first(where: { $0.0.lowercased() == target }) {
            return pair.1.contains("=?") ? RFC2047.decode(pair.1) : pair.1
        }
        return nil
    }

    /// An ASCII name with no quoting hazards is emitted plain; anything else also gets the starred form.
    public static func encodeFilenameParams(_ filename: String) -> String {
        let isASCII = filename.unicodeScalars.allSatisfy { $0.value < 0x80 }
        if isASCII && !filename.contains("\"") && !filename.contains("\\") {
            return "filename=\"\(filename)\""
        }

        var fallback = ""
        for scalar in filename.unicodeScalars {
            if scalar.value >= 0x80 {
                fallback.append("_")
            } else if scalar == "\"" {
                fallback.append("\\\"")
            } else if scalar == "\\" {
                fallback.append("\\\\")
            } else {
                fallback.unicodeScalars.append(scalar)
            }
        }

        let hex = Array("0123456789ABCDEF".utf8)
        var encoded: [UInt8] = []
        for byte in Array(filename.utf8) {
            if isAttributeChar(byte) {
                encoded.append(byte)
            } else {
                encoded.append(UInt8(ascii: "%"))
                encoded.append(hex[Int(byte >> 4)])
                encoded.append(hex[Int(byte & 0x0F)])
            }
        }
        return "filename=\"\(fallback)\"; filename*=UTF-8''\(String(decoding: encoded, as: UTF8.self))"
    }

    private static func decodeExtended(_ value: String) -> String {
        let parts = splitExtended(value)
        let charset = (parts.charset?.isEmpty ?? true) ? "utf-8" : parts.charset!
        return Charsets.decode(Data(percentDecode(parts.payload)), charset: charset)
    }

    /// `charset'lang'payload`. When there are fewer than two apostrophes the whole string is the payload.
    private static func splitExtended(_ value: String) -> (charset: String?, payload: String) {
        let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return (nil, value) }
        return (String(pieces[0]), String(pieces[2]))
    }

    private static func percentDecode(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
                let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2])
            {
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return out
    }

    /// RFC 2231 attribute-char: printable ASCII minus the tspecials and the RFC 2231 markers.
    private static func isAttributeChar(_ byte: UInt8) -> Bool {
        guard (0x21...0x7E).contains(byte) else { return false }
        let excluded = Set("*'%()<>@,;:\\\"/[]?=".utf8)
        return !excluded.contains(byte)
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
