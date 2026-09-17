import Foundation
import GRDB
import MailCore
import Observation
import SwiftUI
import UIKit
import UserNotifications
import os

/// One `db.read` snapshot for the Advanced section (architecture §11 "Sync status line"). Value type so the read
/// closure is `@Sendable`.
nonisolated struct SettingsAdvancedInfo: Sendable, Equatable {
    var accountEmail: String?
    var displayName: String?
    var historyId: String?
    var lastFullSyncAtMs: Int64?
    var lastDeltaSyncAtMs: Int64?
    var hasGmailSignature: Bool
    var pendingOps: Int
    var failedSends: Int

    /// All fields nil / false / 0 — the value used before the first load and when the read throws.
    static let empty = SettingsAdvancedInfo()

    init(
        accountEmail: String? = nil, displayName: String? = nil, historyId: String? = nil,
        lastFullSyncAtMs: Int64? = nil, lastDeltaSyncAtMs: Int64? = nil,
        hasGmailSignature: Bool = false, pendingOps: Int = 0, failedSends: Int = 0
    ) {
        self.accountEmail = accountEmail
        self.displayName = displayName
        self.historyId = historyId
        self.lastFullSyncAtMs = lastFullSyncAtMs
        self.lastDeltaSyncAtMs = lastDeltaSyncAtMs
        self.hasGmailSignature = hasGmailSignature
        self.pendingOps = pendingOps
        self.failedSends = failedSends
    }
}

/// Everything this module needs from `UNUserNotificationCenter`, behind a protocol so the badge rules are testable
/// without a system prompt (architecture §14 #11). ADDITION (D2).
protocol BadgeAuthorizing: Sendable {
    /// `requestAuthorization(options: [.badge])`. Returns `false` on `throw` and on denial. The system prompt appears
    /// at most once per install; a previously denied app gets `false` without a prompt.
    func requestBadgeAuthorization() async -> Bool
    /// `notificationSettings().badgeSetting == .enabled` — detects an authorization revoked in iOS Settings later.
    func isBadgeEnabled() async -> Bool
    /// `try? setBadgeCount(count)`; never throws out.
    func setBadgeCount(_ count: Int) async
}

/// Production implementation. `[.badge]` only — never `.alert`, `.sound` or `.provisional` (architecture §14 #11).
nonisolated struct SystemBadgeAuthorizer: BadgeAuthorizing {
    init() {}

    func requestBadgeAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])) ?? false
    }

    func isBadgeEnabled() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().badgeSetting == .enabled
    }

    func setBadgeCount(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

/// State and side effects of `SettingsScreen` that are not a plain `Settings` field (architecture §8.2). ADDITION
/// (D1): a separate observable object so the badge matrix, the advanced read and the strings are unit-testable
/// without hosting a view.
@Observable final class SettingsModel {
    enum BadgeState: Equatable { case idle, requesting, denied }

    private(set) var info: SettingsAdvancedInfo = .empty
    /// `.requesting` disables the toggle; `.denied` renders the help footer + "Open Settings" button.
    private(set) var badgeState: BadgeState = .idle
    private(set) var isSigningOut = false
    private(set) var isResyncing = false
    /// Bound to the two `confirmationDialog`s of §6.
    var showsSignOutConfirmation = false
    var showsResyncConfirmation = false

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let badge: any BadgeAuthorizing

    /// Keeps a strong reference to `env` (it outlives the sheet). `badge` defaults to the system implementation.
    init(env: AppEnvironment, badge: any BadgeAuthorizing = SystemBadgeAuthorizer()) {
        self.env = env
        self.badge = badge
    }

    /// One `db.read` → `info` (§4.2). Never throws: a failing read logs and leaves `info` unchanged.
    func load() async {
        let snapshot: SettingsAdvancedInfo? = try? await env.db.read { db in
            let all = try SyncStateRepository.all(db)
            let counts = try Queries.outboxCounts(db)
            let sig = all[.sendAsSignature]
            return SettingsAdvancedInfo(
                accountEmail: all[.accountEmail],
                displayName: all[.displayName],
                historyId: all[.historyId],
                lastFullSyncAtMs: all[.lastFullSyncAt].flatMap(Int64.init),
                lastDeltaSyncAtMs: all[.lastDeltaSyncAt].flatMap(Int64.init),
                hasGmailSignature: sig?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                pendingOps: counts.pending,
                failedSends: counts.failed)
        }
        guard let snapshot else {
            Log.ui.error("settings.load failed")
            return
        }
        info = snapshot
    }

    /// The `Settings.showBadge` write path (§4.4). `on == true` requests `[.badge]` first, persists only on success.
    func setBadgeEnabled(_ on: Bool) async {
        if on {
            guard badgeState != .requesting else { return }
            badgeState = .requesting
            if await badge.requestBadgeAuthorization() {
                badgeState = .idle
                env.settings.update { $0.showBadge = true }
                await env.sync.updateBadge()
            } else {
                badgeState = .denied
                env.settings.update { $0.showBadge = false }
                Log.ui.notice("badge authorization denied")
            }
        } else {
            env.settings.update { $0.showBadge = false }
            badgeState = .idle
            await badge.setBadgeCount(0)
        }
    }

    /// Called from `.task`: reconciles a persisted `showBadge == true` with an authorization revoked in iOS Settings.
    func verifyBadgeAuthorization() async {
        guard env.settings.snapshot.showBadge else {
            badgeState = .idle
            return
        }
        if await badge.isBadgeEnabled() {
            badgeState = .idle
            return
        }
        env.settings.update { $0.showBadge = false }
        badgeState = .denied
        await badge.setBadgeCount(0)
        Log.ui.notice("badge authorization revoked, toggle switched off")
    }

    /// `await env.auth.signOut()` (architecture §5.4). Idempotent while `isSigningOut`.
    func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        await env.auth.signOut()
        isSigningOut = false
    }

    /// `await env.sync.requestFullResync()` then `load()` (§4.5). Idempotent while `isResyncing`.
    func fullResync() async {
        guard !isResyncing else { return }
        isResyncing = true
        await env.sync.requestFullResync()
        isResyncing = false
        await load()
    }

    // ---- derived strings (pure given the model's inputs; covered by tests) ----

    /// "Offline" · "Syncing…" · "First sync…" · `SyncStatus.lastError` · "Idle" (§4.6).
    var statusLine: String {
        if env.syncStatus.isOffline { return "Offline" }
        switch env.syncStatus.phase {
        case .syncing: return "Syncing…"
        case .initialSync: return "First sync…"
        case .idle: return env.syncStatus.lastError ?? "Idle"
        }
    }

    /// `SyncStatus.lastSyncAt`, else `max(lastDeltaSyncAtMs, lastFullSyncAtMs)`; "Never" when all three are nil.
    var lastSyncLine: String {
        let date =
            env.syncStatus.lastSyncAt
            ?? [info.lastDeltaSyncAtMs, info.lastFullSyncAtMs]
                .compactMap { $0 }
                .max()
                .map { Date(timeIntervalSince1970: Double($0) / 1000) }
        return date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never"
    }

    /// "<CFBundleShortVersionString> (<CFBundleVersion>)", e.g. "0.1.0 (1)"; missing keys → "—".
    var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        default: return "—"
        }
    }

    /// `info.accountEmail` ?? `env.auth.state.email` ?? "—".
    var accountEmailLine: String {
        info.accountEmail ?? env.auth.state.email ?? "—"
    }
}

/// `Color` ⇄ `"#rrggbb"` for the compose `ColorPicker` (architecture §11 "ColorPicker bound through hex"). ADDITION
/// (D3).
nonisolated enum HexColor {
    /// `"#rrggbb"` (lowercase, `ComposeStyle.isValidHex`) → sRGB `Color`. Any other input → opaque black.
    static func color(_ hex: String) -> Color {
        guard ComposeStyle.isValidHex(hex), let v = UInt32(hex.dropFirst(), radix: 16) else {
            return Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
        }
        return Color(
            .sRGB,
            red: Double((v >> 16) & 0xff) / 255,
            green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255,
            opacity: 1)
    }

    /// sRGB components of `color`, clamped to 0…1, rounded to the nearest byte, formatted `"#%02x%02x%02x"`
    /// (lowercase). Alpha is ignored. Dynamic colours are resolved for `.light`. Unconvertible → `"#000000"`.
    static func hex(_ color: Color) -> String { hex(UIColor(color)) }

    /// Same conversion from `UIColor` (used by `hex(_:)` and directly by tests).
    static func hex(_ color: UIColor) -> String {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
        func byte(_ c: CGFloat) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }
}

/// The non-signature half of the module's user-visible strings (the signature strings ship with
/// `SignatureEditorModel`). ADDITION (D4); architecture §11.
extension SettingsStrings {
    static let signOutTitle = "Sign Out"
    static let signOutConfirmTitle = "Sign out of minimail?"
    static let signOutConfirmDetail = "This deletes the local mail cache on this iPhone. Your mail stays in Gmail."
    static let accountFooter = "Signing out deletes the local mail cache on this iPhone. Your mail stays in Gmail."
    static let composeFooter =
        "Your default font, size and color are applied to the text you type. The quoted original keeps its own styling."
    static let readingFooter = "Remote images can tell the sender that you opened the message."
    static let plainTextTitle = "Plain Text Bodies"
    static let plainTextFooter =
        "Messages open as text instead of a web page, so they appear immediately and remote content can never "
        + "load. Tap Show Original on any message to see it rendered. Replies and forwards are unaffected."
    static let badgeDeniedFooter =
        "Badges are turned off for minimail. Allow them in iOS Settings → Notifications → minimail."
    static let badgeOpenSettings = "Open Settings"
    static let resyncTitle = "Full Resync Now"
    static let resyncConfirmTitle = "Re-download the inbox?"
    static let resyncConfirmDetail =
        "minimail fetches the inbox list from Gmail again. Cached messages that are still in the inbox are kept."
    static let advancedFooter = "A full resync is only needed when the local cache and Gmail disagree."
}
