import SwiftUI

/// The app mark at control size: minimail's three tittles, stacked.
///
/// `minimal` carries two tittles, `minimail` three, and the dot the name gained takes the accent. In the
/// toolbar that third dot earns a second job — the filled one says which mailbox the list is showing, and
/// the switcher's menu has exactly these three destinations.
///
/// The tittles sit over letters 2, 4 and 7 of the wordmark, so the gaps run short-then-long. `centers`
/// keeps that 2:3 ratio; spacing them evenly is what would turn the mark into an ellipsis.
struct MailboxDots: View {
    /// Which dot is filled. The order matches the switcher's menu: Inbox, Today, Labels.
    nonisolated enum Slot: Int, Hashable, Sendable {
        case inbox = 0
        case today = 1
        case labels = 2

        init(scope: InboxScope) {
            switch scope {
            case .inbox: self = .inbox
            case .today: self = .today
            case .label: self = .labels
            }
        }
    }

    let active: Slot

    @ThemeTokensReader private var themeTokens

    /// Dot centres down a 24pt square: gaps of 6 and 9, the wordmark's 2:3 rhythm.
    nonisolated static let centers: [CGFloat] = [4, 10, 19]
    private static let radius: CGFloat = 2.5
    private static let side: CGFloat = 24

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Self.centers.indices, id: \.self) { index in
                Circle()
                    .fill(index == active.rawValue ? themeTokens.accent : themeTokens.secondaryText)
                    .frame(width: Self.radius * 2, height: Self.radius * 2)
                    .offset(y: Self.centers[index] - Self.radius)
            }
        }
        .frame(width: Self.side, height: Self.side, alignment: .top)
    }
}
