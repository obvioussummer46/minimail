import Foundation

/// RFC 4648 §5 "URL and filename safe" base64, the alphabet Gmail uses for `raw` message payloads.
public enum Base64URL {

    /// Encodes as one line, `-`/`_` alphabet, padding kept. Empty input gives an empty string.
    public static func encode(_ data: Data) -> String {
        var bytes = Array(data.base64EncodedString().utf8)
        for index in bytes.indices {
            switch bytes[index] {
            case UInt8(ascii: "+"): bytes[index] = UInt8(ascii: "-")
            case UInt8(ascii: "/"): bytes[index] = UInt8(ascii: "_")
            default: break
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Decodes padded or unpadded input in either alphabet. Returns nil for any character outside the
    /// alphabet, for `=` anywhere but at the end, and for an unpadded length congruent to 1 modulo 4.
    public static func decode(_ string: String) -> Data? {
        var bytes = Array(string.utf8)
        if bytes.isEmpty { return Data() }

        for index in bytes.indices {
            switch bytes[index] {
            case UInt8(ascii: "-"): bytes[index] = UInt8(ascii: "+")
            case UInt8(ascii: "_"): bytes[index] = UInt8(ascii: "/")
            default: break
            }
            guard isAllowed(bytes[index]) else { return nil }
        }

        var padding = 0
        while bytes.last == UInt8(ascii: "=") {
            bytes.removeLast()
            padding += 1
            if padding > 2 { return nil }
        }
        // An `=` that survived the strip sat somewhere other than the end.
        if bytes.contains(UInt8(ascii: "=")) { return nil }

        switch bytes.count % 4 {
        case 1: return nil
        case 2: bytes.append(contentsOf: [UInt8(ascii: "="), UInt8(ascii: "=")])
        case 3: bytes.append(UInt8(ascii: "="))
        default: break
        }
        return Data(base64Encoded: Data(bytes))
    }

    private static func isAllowed(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return true
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return true
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return true
        case UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "="): return true
        default: return false
        }
    }
}
