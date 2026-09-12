import Foundation

/// One inner request of an HTTP batch.
public struct BatchCall: Sendable, Equatable {
    /// Content-ID token: ASCII, no whitespace and no angle brackets.
    public var id: String
    public var method: String
    /// Host-relative, starting with a slash, query string included and already percent-encoded.
    public var path: String
    /// UTF-8 JSON. When present the part declares `application/json`.
    public var jsonBody: Data?

    public init(id: String, method: String, path: String, jsonBody: Data? = nil) {
        self.id = id
        self.method = method
        self.path = path
        self.jsonBody = jsonBody
    }
}

/// One inner response, matched back to its request by id.
public struct BatchPartResponse: Sendable, Equatable {
    public var id: String
    public var status: Int
    /// Inner body without the CRLF that precedes the next delimiter. Empty for header-only parts.
    public var body: Data

    public init(id: String, status: Int, body: Data) {
        self.id = id
        self.status = status
        self.body = body
    }
}

public enum BatchCodecError: Error, Sendable, Equatable {
    /// The boundary never appears: an HTML error page, an empty body, or the wrong boundary.
    case noDelimiter
    case truncated
    case noParts
    case malformedPart(index: Int)
    case missingContentID(index: Int)
    case badStatusLine(index: Int)
}

/// Encodes and decodes the `multipart/mixed` envelope Gmail's batch endpoint speaks.
public enum BatchCodec {

    private static let crlf: [UInt8] = [0x0D, 0x0A]

    /// Byte-exact `multipart/mixed` body. An empty call list still produces a valid close delimiter.
    public static func encode(_ calls: [BatchCall], boundary: String) -> Data {
        precondition(!boundary.isEmpty, "boundary must not be empty")
        precondition(boundary.count <= 70, "boundary must be at most 70 characters")
        precondition(boundary.allSatisfy { $0.isASCII }, "boundary must be ASCII")

        var out: [UInt8] = []
        for call in calls {
            precondition(call.path.hasPrefix("/"), "path must be host-relative")
            precondition(!call.id.isEmpty, "id must not be empty")
            precondition(
                !call.id.contains(where: { $0 == "<" || $0 == ">" || $0.isWhitespace }),
                "id must not contain angle brackets or whitespace"
            )

            out += Array("--\(boundary)".utf8)
            out += crlf
            out += Array("Content-Type: application/http".utf8)
            out += crlf
            out += Array("Content-ID: <\(call.id)>".utf8)
            out += crlf
            out += crlf
            out += Array("\(call.method) \(call.path)".utf8)
            out += crlf
            if let jsonBody = call.jsonBody {
                out += Array("Content-Type: application/json".utf8)
                out += crlf
                out += crlf
                out += Array(jsonBody)
                out += crlf
            }
            out += crlf
        }
        out += Array("--\(boundary)--".utf8)
        out += crlf
        return Data(out)
    }

    /// The `boundary` parameter of a multipart content type, or nil when this is not a multipart response.
    public static func boundary(fromContentType ct: String) -> String? {
        let value = ContentTypeParams.parse(ct)
        guard value.type.lowercased().hasPrefix("multipart/"),
            let boundary = value.param("boundary"),
            !boundary.isEmpty
        else { return nil }
        return boundary
    }

    /// Splits the response into its parts. Order is preserved, but callers match on id rather than position.
    public static func decode(body: Data, boundary: String) throws -> [BatchPartResponse] {
        // The first delimiter has no leading CRLF, so prepending one makes every delimiter identical.
        let bytes = crlf + Array(body)
        let delimiter = Array("\r\n--\(boundary)".utf8)
        let doubleCRLF = crlf + crlf

        guard var cursor = firstRange(delimiter, in: bytes, from: 0) else {
            throw BatchCodecError.noDelimiter
        }

        var parts: [BatchPartResponse] = []
        while true {
            let after = cursor.upperBound
            if bytes[after...].starts(with: Array("--".utf8)) { break }
            guard let endOfLine = firstRange(crlf, in: bytes, from: after) else {
                throw BatchCodecError.truncated
            }
            let start = endOfLine.upperBound
            guard let next = firstRange(delimiter, in: bytes, from: start) else {
                throw BatchCodecError.truncated
            }
            parts.append(
                try parsePart(Array(bytes[start..<next.lowerBound]), index: parts.count, doubleCRLF: doubleCRLF)
            )
            cursor = next
        }

        if parts.isEmpty { throw BatchCodecError.noParts }
        return parts
    }

    private static func parsePart(
        _ slice: [UInt8],
        index: Int,
        doubleCRLF: [UInt8]
    ) throws -> BatchPartResponse {
        guard let separator = firstRange(doubleCRLF, in: slice, from: 0) else {
            throw BatchCodecError.malformedPart(index: index)
        }
        let outer = Array(slice[..<separator.lowerBound])
        let inner = Array(slice[separator.upperBound...])

        guard let id = contentID(in: outer), !id.isEmpty else {
            throw BatchCodecError.missingContentID(index: index)
        }

        let statusLineEnd = firstRange(crlf, in: inner, from: 0)
        let statusLineBytes = statusLineEnd.map { Array(inner[..<$0.lowerBound]) } ?? inner
        let statusLine = String(decoding: statusLineBytes, as: UTF8.self)
        let tokens = statusLine.split(separator: " ").map(String.init)
        guard tokens.count >= 2, tokens[0].hasPrefix("HTTP/"), let status = Int(tokens[1]) else {
            throw BatchCodecError.badStatusLine(index: index)
        }

        let rest = statusLineEnd.map { Array(inner[$0.upperBound...]) } ?? []
        let bodyBytes: [UInt8]
        if let headerEnd = firstRange(doubleCRLF, in: rest, from: 0) {
            bodyBytes = Array(rest[headerEnd.upperBound...])
        } else {
            bodyBytes = []
        }
        return BatchPartResponse(id: id, status: status, body: Data(bodyBytes))
    }

    private static func contentID(in outer: [UInt8]) -> String? {
        for line in String(decoding: outer, as: UTF8.self).components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            guard line[line.startIndex..<colon].lowercased() == "content-id" else { continue }
            var value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if value.hasPrefix("<") { value.removeFirst() }
            if value.hasSuffix(">") { value.removeLast() }
            if value.hasPrefix("response-") { value.removeFirst("response-".count) }
            return value
        }
        return nil
    }

    /// A naive byte search: the patterns are short and Foundation's own search is not relied on here.
    private static func firstRange(
        _ pattern: [UInt8],
        in bytes: [UInt8],
        from start: Int
    ) -> Range<Int>? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        var position = max(0, start)
        let last = bytes.count - pattern.count
        while position <= last {
            var matched = true
            for offset in 0..<pattern.count where bytes[position + offset] != pattern[offset] {
                matched = false
                break
            }
            if matched { return position..<(position + pattern.count) }
            position += 1
        }
        return nil
    }
}
