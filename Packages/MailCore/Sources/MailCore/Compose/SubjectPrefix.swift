import Foundation

/// Subject prefixes. Adding one is conservative: an existing prefix is never rewritten, only recognised.
public enum SubjectPrefix {

    private static let knownPrefixes = ["re", "fwd", "fw", "aw", "wg"]

    public static func reply(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("re:") ? trimmed : "Re: " + trimmed
    }

    public static func forward(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("fwd:") ? trimmed : "Fwd: " + trimmed
    }

    /// Strips every leading reply or forward marker, including the `Re[2]:` counter form, for list display.
    public static func stripForDisplay(_ s: String) -> String {
        var current = s.trimmingCharacters(in: .whitespacesAndNewlines)
        outer: while true {
            let lowered = current.lowercased()
            for prefix in knownPrefixes where lowered.hasPrefix(prefix) {
                var rest = Substring(current.dropFirst(prefix.count))
                if rest.first == "[" {
                    guard let close = rest.firstIndex(of: "]") else { continue }
                    let digits = rest[rest.index(after: rest.startIndex)..<close]
                    guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { continue }
                    rest = rest[rest.index(after: close)...]
                }
                guard rest.first == ":" else { continue }
                current = String(rest.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                continue outer
            }
            return current
        }
    }
}
