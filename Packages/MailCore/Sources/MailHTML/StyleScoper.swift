import Foundation

/// Confines a message's `<style>` rules to that message's own body inside the shared thread document.
///
/// Every message in a thread shares one HTML document, so an unscoped `<style>` block could restyle the
/// renderer's own chrome (`.mm-hdr`, `.mm-att`) or another message's body — hiding a sender line or dressing
/// a link up as an attachment chip. The scoper prefixes every selector with the owning message's scope,
/// turns `html`/`body` selectors into the scope itself, keeps conditional at-rules (`@media`, `@supports`)
/// with their inner rules scoped, and drops every other at-rule (`@font-face`, `@keyframes`, `@import`,
/// `@page`, `@charset`, `@namespace`). Pure; never throws. Unbalanced input is cut off where it stops parsing.
public enum StyleScoper {
    /// `.mm-msg[data-id="<id>"] .mm-body`, with the id reduced to identifier characters so it can never close
    /// the attribute selector.
    public static func scope(forMessageId id: String) -> String {
        let safe = String(id.unicodeScalars.filter { isIdentifierScalar($0) })
        return ".mm-msg[data-id=\"\(safe)\"] .mm-body"
    }

    public static func scope(_ css: String, scope: String) -> String {
        scopeRules(Array(stripComments(css).unicodeScalars), scope: scope, depth: 0)
    }

    /// At-rules whose block holds ordinary rules that must be scoped in place.
    private static let conditionalAtRules: Set<String> = ["@media", "@supports", "@container", "@layer"]

    /// Conditional at-rules nest, and `scopeRules` recurses once per level. Untrusted email can nest them
    /// thousands deep to overflow the stack (far smaller on iOS than the test host), so recursion is capped and
    /// anything nested deeper is dropped. Real email never approaches this.
    private static let maxNestingDepth = 16

    // MARK: - Rules

    private static func scopeRules(_ s: [Unicode.Scalar], scope: String, depth: Int) -> String {
        var out = ""
        var i = 0
        while i < s.count {
            if isSpace(s[i]) || s[i] == ";" {
                i += 1
                continue
            }
            // The prelude runs up to `{` (a rule or block at-rule) or `;` (a statement at-rule such as @import).
            var prelude = String.UnicodeScalarView()
            var j = i
            var terminator: Unicode.Scalar? = nil
            while j < s.count {
                let c = s[j]
                if c == "\"" || c == "'" {
                    let end = skipString(s, from: j)
                    prelude.append(contentsOf: s[j..<end])
                    j = end
                    continue
                }
                if c == "{" || c == ";" || c == "}" {
                    terminator = c
                    break
                }
                prelude.append(c)
                j += 1
            }
            guard let terminator else { break }
            if terminator != "{" {
                // A statement at-rule (dropped) or a stray `}` (garbage).
                i = j + 1
                continue
            }
            guard let blockEnd = matchingBrace(s, openAt: j) else { break }
            let body = Array(s[(j + 1)..<blockEnd])
            let preludeText = String(prelude).trimmingCharacters(in: .whitespacesAndNewlines)
            i = blockEnd + 1
            if preludeText.isEmpty { continue }

            if preludeText.hasPrefix("@") {
                let name = String(preludeText.prefix { !isSpace($0) && $0 != "(" }).lowercased()
                if conditionalAtRules.contains(name), depth < maxNestingDepth {
                    out += preludeText + "{" + scopeRules(body, scope: scope, depth: depth + 1) + "}"
                }
                continue
            }
            out += scopeSelectors(preludeText, scope: scope) + "{" + String(String.UnicodeScalarView(body)) + "}"
        }
        return out
    }

    // MARK: - Selectors

    /// Prefixes each comma-separated selector with `scope`. `html`, `body`, `html body` and `*` collapse to the
    /// scope itself; a leading `html`/`body` token followed by a combinator is replaced by the scope.
    static func scopeSelectors(_ list: String, scope: String) -> String {
        var scoped: [String] = []
        for raw in splitTopLevel(Array(list.unicodeScalars), on: ",") {
            let selector = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if selector.isEmpty { continue }
            let lower = selector.lowercased()
            if lower == "html" || lower == "body" || lower == "html body" || lower == "*" {
                scoped.append(scope)
                continue
            }
            var rest = selector
            var stripped = false
            while let token = leadingRootToken(rest) {
                rest = String(rest.dropFirst(token.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                stripped = true
            }
            if stripped {
                scoped.append(rest.isEmpty ? scope : scope + " " + rest)
            } else {
                scoped.append(scope + " " + selector)
            }
        }
        return scoped.isEmpty ? scope : scoped.joined(separator: ",")
    }

    /// `"html"` or `"body"` when `selector` starts with that word followed by whitespace or a combinator.
    private static func leadingRootToken(_ selector: String) -> String? {
        let lower = selector.lowercased()
        for word in ["html", "body"] where lower.hasPrefix(word) {
            let after = lower.dropFirst(word.count)
            guard let next = after.unicodeScalars.first else { return nil }
            if isSpace(next) || next == ">" || next == "+" || next == "~" { return word }
        }
        return nil
    }

    private static func splitTopLevel(_ s: [Unicode.Scalar], on separator: Unicode.Scalar) -> [String] {
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        var depth = 0
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\"" || c == "'" {
                let end = skipString(s, from: i)
                current.append(contentsOf: s[i..<end])
                i = end
                continue
            }
            if c == "(" || c == "[" { depth += 1 }
            if c == ")" || c == "]" { depth = max(0, depth - 1) }
            if c == separator && depth == 0 {
                parts.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(c)
            }
            i += 1
        }
        parts.append(String(current))
        return parts
    }

    // MARK: - Lexing helpers

    /// Index just past the string that opens at `from`; an unterminated string ends at the newline or the end.
    private static func skipString(_ s: [Unicode.Scalar], from: Int) -> Int {
        let quote = s[from]
        var k = from + 1
        while k < s.count {
            let c = s[k]
            if c == "\\" {
                k += 2
                continue
            }
            if c == quote { return k + 1 }
            if c == "\n" { return k }
            k += 1
        }
        return s.count
    }

    /// Index of the `}` matching the `{` at `openAt`, or nil when unbalanced.
    private static func matchingBrace(_ s: [Unicode.Scalar], openAt: Int) -> Int? {
        var depth = 0
        var k = openAt
        while k < s.count {
            let c = s[k]
            if c == "\"" || c == "'" {
                k = skipString(s, from: k)
                continue
            }
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { return k }
            }
            k += 1
        }
        return nil
    }

    /// Removes `/* … */` comments.
    static func stripComments(_ css: String) -> String {
        var out = String.UnicodeScalarView()
        let s = Array(css.unicodeScalars)
        var i = 0
        while i < s.count {
            if s[i] == "/", i + 1 < s.count, s[i + 1] == "*" {
                var k = i + 2
                while k + 1 < s.count, !(s[k] == "*" && s[k + 1] == "/") { k += 1 }
                i = min(s.count, k + 2)
                continue
            }
            out.append(s[i])
            i += 1
        }
        return String(out)
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}"
    }

    private static func isSpace(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r"
    }

    private static func isIdentifierScalar(_ s: Unicode.Scalar) -> Bool {
        switch s {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "-": return true
        default: return false
        }
    }
}
