import Foundation

/// RFC 5322 §2.2.3 folding: removing it on the way in, applying it on the way out.
public enum HeaderFolding {

    /// Removes every line break that is immediately followed by a space or tab, keeping that whitespace,
    /// then drops trailing breaks. A break with no following whitespace is left alone.
    public static func unfold(_ raw: String) -> String {
        let scalars = Array(raw.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\r", index + 2 < scalars.count, scalars[index + 1] == "\n",
                scalars[index + 2] == " " || scalars[index + 2] == "\t"
            {
                index += 2
                continue
            }
            if (scalar == "\n" || scalar == "\r"), index + 1 < scalars.count,
                scalars[index + 1] == " " || scalars[index + 1] == "\t"
            {
                index += 1
                continue
            }
            out.append(scalar)
            index += 1
        }
        var result = String(out)
        while let last = result.unicodeScalars.last, last == "\r" || last == "\n" {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    /// `Field: a, b, c` with a CRLF SP continuation whenever the next mailbox would push the line past 78.
    public static func foldAddressList(_ list: [Mailbox], fieldName: String) -> String {
        fold(list.map { $0.serialized() }, fieldName: fieldName, separator: ",", joiner: ", ")
    }

    /// `Field: <a> <b>` with the same rule and no comma. An id longer than the limit sits alone on its line.
    public static func foldMessageIDs(_ ids: [String], fieldName: String) -> String {
        fold(ids, fieldName: fieldName, separator: "", joiner: " ")
    }

    private static func fold(
        _ pieces: [String],
        fieldName: String,
        separator: String,
        joiner: String
    ) -> String {
        var line = fieldName + ":"
        var out = ""
        var first = true
        for piece in pieces {
            if first {
                line += " " + piece
                first = false
            } else if lengthOfLastLine(line) + joiner.count + lengthOfFirstLine(piece) > 78 {
                out += line + separator + "\r\n"
                line = " " + piece
            } else {
                line += joiner + piece
            }
        }
        return out + line
    }

    private static func lengthOfLastLine(_ string: String) -> Int {
        guard let range = string.range(of: "\r\n", options: .backwards) else { return string.count }
        return string.distance(from: range.upperBound, to: string.endIndex)
    }

    private static func lengthOfFirstLine(_ string: String) -> Int {
        guard let range = string.range(of: "\r\n") else { return string.count }
        return string.distance(from: string.startIndex, to: range.lowerBound)
    }
}
