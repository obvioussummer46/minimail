import Foundation

/// Assembles an `OutgoingMessage` into the RFC 5322 bytes Gmail accepts as `raw`.
///
/// Two shapes. Without attachments the top level is `multipart/alternative` holding the plain and HTML parts.
/// With attachments the top level is `multipart/mixed` holding that alternative plus one base64 part per file.
public enum MIMEBuilder {

    private static let crlf: [UInt8] = [0x0D, 0x0A]

    /// Deterministic for a fixed `boundaries`. Never throws. Output always ends with CRLF.
    public static func build(_ m: OutgoingMessage, boundaries: BoundaryGenerator = .random) -> Data {
        var headers: [String] = []
        headers.append(HeaderFolding.foldAddressList([m.from], fieldName: "From"))
        if !m.to.isEmpty { headers.append(HeaderFolding.foldAddressList(m.to, fieldName: "To")) }
        if !m.cc.isEmpty { headers.append(HeaderFolding.foldAddressList(m.cc, fieldName: "Cc")) }
        headers.append("Subject: " + RFC2047.encodeIfNeeded(m.subject, firstLineOffset: 9))
        headers.append("Date: " + HeaderDate.rfc5322(m.date, timeZone: m.timeZone))
        headers.append("Message-ID: " + (MessageIDs.normalize(m.messageID) ?? m.messageID))
        if let inReplyTo = m.inReplyTo.flatMap(MessageIDs.normalize) {
            headers.append("In-Reply-To: " + inReplyTo)
        }
        let references = m.references.compactMap(MessageIDs.normalize)
        if !references.isEmpty {
            headers.append(HeaderFolding.foldMessageIDs(references, fieldName: "References"))
        }
        headers.append("MIME-Version: 1.0")

        let altBoundary = boundaries.boundary(kind: "alt")
        let textPart = part(
            headers: [
                "Content-Type: text/plain; charset=\"UTF-8\"",
                "Content-Transfer-Encoding: quoted-printable",
            ],
            body: Array(QuotedPrintable.encode(Data(ensureTrailingCRLF(normalizeCRLF(m.textBody)))))
        )
        let htmlPart = part(
            headers: [
                "Content-Type: text/html; charset=\"UTF-8\"",
                "Content-Transfer-Encoding: quoted-printable",
            ],
            body: Array(QuotedPrintable.encode(Data(ensureTrailingCRLF(normalizeCRLF(m.htmlBody)))))
        )
        let altBody = multipart(boundary: altBoundary, parts: [textPart, htmlPart])

        var body: [UInt8]
        if m.attachments.isEmpty {
            headers.append("Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"")
            body = altBody
        } else {
            let mixedBoundary = boundaries.boundary(kind: "mixed")
            headers.append("Content-Type: multipart/mixed; boundary=\"\(mixedBoundary)\"")
            var parts: [[UInt8]] = [
                part(
                    headers: ["Content-Type: multipart/alternative; boundary=\"\(altBoundary)\""],
                    body: altBody
                )
            ]
            for attachment in m.attachments {
                let name = sanitizedFilename(attachment.filename)
                let mime = sanitizedMimeType(attachment.mimeType)
                let nameParam = RFC2231.encodeFilenameParams(name)
                let asciiName = firstQuotedValue(nameParam) ?? name
                parts.append(
                    part(
                        headers: [
                            "Content-Type: \(mime); name=\"\(asciiName)\"",
                            "Content-Disposition: attachment; \(nameParam); size=\(attachment.data.count)",
                            "Content-Transfer-Encoding: base64",
                        ],
                        body: base64Lines(attachment.data)
                    )
                )
            }
            body = multipart(boundary: mixedBoundary, parts: parts)
        }

        var out: [UInt8] = []
        out.reserveCapacity(body.count + 1024)
        out += Array(headers.joined(separator: "\r\n").utf8)
        out += crlf
        out += crlf
        out += body
        out += crlf
        return Data(out)
    }

    /// Any line-break convention in, CRLF out.
    private static func normalizeCRLF(_ string: String) -> [UInt8] {
        var out: [UInt8] = []
        let bytes = Array(string.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0D {
                out += crlf
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if bytes[index] == 0x0A {
                out += crlf
                index += 1
                continue
            }
            out.append(bytes[index])
            index += 1
        }
        return out
    }

    private static func ensureTrailingCRLF(_ bytes: [UInt8]) -> [UInt8] {
        if bytes.count >= 2, bytes[bytes.count - 2] == 0x0D, bytes[bytes.count - 1] == 0x0A {
            return bytes
        }
        return bytes + crlf
    }

    /// Standard base64, wrapped at 76 columns, with no trailing break.
    private static func base64Lines(_ data: Data) -> [UInt8] {
        guard !data.isEmpty else { return [] }
        let encoded = Array(data.base64EncodedData())
        var out: [UInt8] = []
        out.reserveCapacity(encoded.count + encoded.count / 76 * 2)
        var index = 0
        while index < encoded.count {
            let end = min(index + 76, encoded.count)
            if index > 0 { out += crlf }
            out += encoded[index..<end]
            index = end
        }
        return out
    }

    private static func part(headers: [String], body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for header in headers {
            out += Array(header.utf8)
            out += crlf
        }
        out += crlf
        out += body
        return out
    }

    private static func multipart(boundary: String, parts: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        let marker = Array("--\(boundary)".utf8)
        for part in parts {
            out += marker
            out += crlf
            out += part
            out += crlf
        }
        out += marker
        out += Array("--".utf8)
        return out
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        var out = ""
        for scalar in filename.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == "\\"
                || scalar == "\""
            {
                out.append("_")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        while out.hasPrefix(".") { out.removeFirst() }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "attachment" : out
    }

    private static func sanitizedMimeType(_ type: String) -> String {
        let fallback = "application/octet-stream"
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty,
            trimmed.unicodeScalars.allSatisfy({ $0.value < 0x80 }),
            trimmed.filter({ $0 == "/" }).count == 1,
            !trimmed.contains(" "),
            !trimmed.contains(";"),
            !trimmed.contains("\"")
        else { return fallback }
        return trimmed
    }

    /// The ASCII fallback that `RFC2231.encodeFilenameParams` put inside the first quoted string.
    private static func firstQuotedValue(_ parameters: String) -> String? {
        guard let open = parameters.firstIndex(of: "\"") else { return nil }
        var out = ""
        var escaped = false
        var index = parameters.index(after: open)
        while index < parameters.endIndex {
            let character = parameters[index]
            if escaped {
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return out
            } else {
                out.append(character)
            }
            index = parameters.index(after: index)
        }
        return out
    }
}
