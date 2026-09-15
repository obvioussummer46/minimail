import Foundation
import Observation

/// Observable sync state for banners, the initial-sync footer, the Outbox section and Settings → Advanced.
/// Main actor (implicit). One instance.
@Observable final class SyncStatus {
    enum Phase: Equatable { case idle, syncing, initialSync }
    var phase: Phase = .idle
    /// Last network attempt failed with `GmailError.offline`; cleared by the next successful request.
    var isOffline = false
    /// `GmailError.userMessage` (or "Database unavailable"); nil after a successful run.
    var lastError: String?
    /// End of the last successful run (any reason).
    var lastSyncAt: Date?
    /// Outbox rows in state pending/inFlight (both kinds).
    var pendingOps = 0
    /// Outbox rows kind = send, state = failed.
    var failedSends = 0
    /// ADDITION (D3): reason of the run that last changed `phase` (Settings → Advanced status line; tests).
    var lastRunReason: SyncReason?
    init() {}
}
