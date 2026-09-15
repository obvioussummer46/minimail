import Foundation
import MailCore
import SwiftSoup

/// Picks how a message body should adapt to dark mode (`[html-rendering §3.3]`): mails that declare colour-scheme
/// support render natively; mails with author backgrounds or table+image layouts get a light "card"; everything
/// else gets plain colour inversion.
public enum DarkStrategyClassifier {
    /// ICU source of the background test: a `background`/`background-color` declaration whose value is not
    /// `transparent`/`none`/`inherit`.
    public static let backgroundPattern = #"background(-color)?\s*:\s*(?!transparent|none|inherit)"#

    private static let backgroundRegex = try? NSRegularExpression(
        pattern: backgroundPattern, options: [.caseInsensitive])

    public static func classify(_ doc: Document, sawBackgroundAttribute: Bool = false) -> DarkStrategy {
        let html = (try? doc.body()?.html()) ?? ""
        let lower = html.lowercased()
        if lower.contains("prefers-color-scheme") || lower.contains("color-scheme:")
            || lower.contains("supported-color-schemes")
        {
            return .native
        }

        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        let hasBackground =
            (backgroundRegex?.firstMatch(in: lower, options: [], range: range) != nil)
            || lower.contains("bgcolor=") || sawBackgroundAttribute
        let imageHeavy = ((try? doc.select("img").size()) ?? 0) >= 3
        let tableLayout = ((try? doc.select("table").size()) ?? 0) >= 2
        return (hasBackground || (imageHeavy && tableLayout)) ? .card : .plain
    }
}
