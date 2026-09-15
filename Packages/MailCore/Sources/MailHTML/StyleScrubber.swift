import Foundation

/// Removes CSS constructs the allowlist cannot express as property names: `@import`, `@font-face`, non-`data:`
/// `url()`, IE `expression`/`behavior`, XBL `-moz-binding`, leftover `javascript:` scheme text and fixed/absolute
/// positioning. Applied to the whole cleaned fragment (inline `style` attributes included).
public enum StyleScrubber {
    /// Regex sources (ICU, case-insensitive), applied in order.
    public static let patterns: [String] = [
        #"@import[^;]*;"#,
        #"@font-face\s*\{[^}]*\}"#,
        #"url\s*\((?!\s*['"]?data:)[^)]*\)"#,
        #"expression\s*\("#,
        #"behavior\s*:"#,
        #"-moz-binding\s*:"#,
        #"javascript:"#,
        #"position\s*:\s*fixed"#,
        #"position\s*:\s*absolute"#,
    ]

    /// Compiled once. A compile failure is a programmer error (`patterns` is a constant) → `preconditionFailure`.
    private static let compiled: [NSRegularExpression] = patterns.map { pattern in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            preconditionFailure("StyleScrubber pattern failed to compile: \(pattern)")
        }
        return regex
    }

    /// Removes every match of every pattern (replacement `""`). Pure; never throws. Idempotent. `scrub("")` → `""`.
    public static func scrub(_ html: String) -> String {
        var current = html
        for regex in compiled {
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            current = regex.stringByReplacingMatches(in: current, options: [], range: range, withTemplate: "")
        }
        return current
    }
}
