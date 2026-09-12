import Foundation

/// One RFC 5322 mailbox. `addr` keeps the case it arrived in; comparisons go through `key`.
public struct Mailbox: Sendable, Hashable, Codable {
    public var name: String?
    public var addr: String

    public init(name: String?, addr: String) {
        self.name = name
        self.addr = addr
    }

    public var key: String { addr.lowercased() }

    public var displayName: String { name ?? addr }

    /// `name <addr>`. The name is left bare when every character is atext or a space, quoted when it is ASCII
    /// with specials, and encoded as RFC 2047 words when it is not ASCII. A missing or blank name gives the
    /// bare address.
    public func serialized() -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return addr }

        if trimmed.unicodeScalars.contains(where: { $0.value > 0x7F }) {
            return RFC2047.encodeIfNeeded(trimmed, firstLineOffset: 0) + " <" + addr + ">"
        }

        if trimmed.unicodeScalars.allSatisfy(isAtextOrSpace) {
            return trimmed + " <" + addr + ">"
        }

        let escaped =
            trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\" <" + addr + ">"
    }

    /// RFC 5322 §3.2.3 atext, plus the space that a bare display phrase may contain.
    private func isAtextOrSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", " ":
            return true
        case "!", "#", "$", "%", "&", "'", "*", "+", "-", "/", "=", "?", "^", "_", "`", "{", "|", "}", "~":
            return true
        default:
            return false
        }
    }
}
