import Foundation

/// Hex colour strings (`#rrggbb`, lowercase) resolved by the app for the current colour scheme and
/// handed to the thread document template. Keeping them as plain strings lets `MailCore` stay free of
/// UIKit and SwiftUI.
public struct ThemeCSSTokens: Sendable, Equatable {
    public var background: String
    public var surface: String
    public var text: String
    public var secondaryText: String
    public var accent: String
    public var separator: String
    public var link: String
    public var cardBackground: String

    public init(
        background: String,
        surface: String,
        text: String,
        secondaryText: String,
        accent: String,
        separator: String,
        link: String,
        cardBackground: String
    ) {
        self.background = background
        self.surface = surface
        self.text = text
        self.secondaryText = secondaryText
        self.accent = accent
        self.separator = separator
        self.link = link
        self.cardBackground = cardBackground
    }
}
