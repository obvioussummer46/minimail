import SwiftUI

/// The app mark at control size: minimail's three tittles, stacked.
///
/// `minimal` carries two tittles, `minimail` three, and the dot the name gained takes the accent. The mark
/// is drawn exactly as the app icon draws it — two idle dots, accent on the last — so the switcher reads as
/// the logo; which mailbox is showing is the button's accessibility value, not the mark's colours.
///
/// The tittles sit over letters 2, 4 and 7 of the wordmark, so the gaps run short-then-long. `centers`
/// keeps that 2:3 ratio; spacing them evenly is what would turn the mark into an ellipsis.
struct MailboxDots: View {
    @ThemeTokensReader private var themeTokens

    /// Dot centres down a 24pt square: gaps of 6 and 9, the wordmark's 2:3 rhythm.
    nonisolated static let centers: [CGFloat] = [4, 10, 19]
    /// The dot the name gained; the same one the icon paints in the accent.
    nonisolated static let accentIndex = 2
    private static let radius: CGFloat = 2.5
    private static let side: CGFloat = 24

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Self.centers.indices, id: \.self) { index in
                Circle()
                    .fill(index == Self.accentIndex ? themeTokens.accent : themeTokens.secondaryText)
                    .frame(width: Self.radius * 2, height: Self.radius * 2)
                    .offset(y: Self.centers[index] - Self.radius)
            }
        }
        .frame(width: Self.side, height: Self.side, alignment: .top)
    }
}
