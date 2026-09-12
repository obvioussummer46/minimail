import Foundation
import MailCore
import SwiftSoup

/// Proves the `MailHTML` target links `MailCore` and `SwiftSoup`. Not used by the app; module 08 replaces it.
public enum MailHTMLPackage {
    public static let name = "MailHTML"

    /// Plain-text content of `html`, via SwiftSoup. Rethrows SwiftSoup parse errors.
    public static func textContent(ofHTML html: String) throws -> String {
        try SwiftSoup.parse(html).text()
    }

    /// Present only so the target has a compile-time reference to `MailCore`.
    public static var defaultComposeCSS: String { ComposeStyle().inlineCSS }
}
