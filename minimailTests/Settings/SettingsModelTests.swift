import GRDB
import MailCore
import XCTest

@testable import minimail

/// Spec 13 §7.1. Drives `SettingsModel` directly with a stub badge authorizer so the badge matrix, the advanced
/// read and the derived strings are checked without a system prompt.
nonisolated final class SettingsModelTests: XCTestCase {
    private var env: AppEnvironment!
    private static let seedNow: Int64 = 1_757_500_000_000

    @MainActor override func setUp() async throws {
        env = AppEnvironment(testing: true)
    }

    @MainActor override func tearDown() async throws {
        // `fullResync()` kicks an unstructured `sync.run`; quiesce it so a leaked run cannot outlive the test.
        await env.sync.cancelAll()
        await env.outbox.cancelAll()
        env = nil
    }

    // MARK: - Fixtures

    @MainActor
    private func seedSyncState(
        historyId: String? = "1234530", displayName: String? = "Max Mustermann",
        email: String? = "max.mustermann@example.com", signature: String? = "<div>Sig</div>",
        deltaAtMs: Int64? = SettingsModelTests.seedNow
    ) async throws {
        try await env.db.write { db in
            if let email { try SyncStateRepository.set(db, .accountEmail, email) }
            if let displayName { try SyncStateRepository.set(db, .displayName, displayName) }
            if let historyId { try SyncStateRepository.set(db, .historyId, historyId) }
            if let deltaAtMs { try SyncStateRepository.set(db, .lastDeltaSyncAt, String(deltaAtMs)) }
            if let signature { try SyncStateRepository.set(db, .sendAsSignature, signature) }
        }
    }

    private func sendJob(threadId: String = "t1") -> SendJob {
        SendJob(
            mode: .forward, originalMessageId: "m1", threadId: threadId, messageID: "<new@example.com>",
            to: [Mailbox(name: "Bob", addr: "bob@example.com")], cc: [], subject: "Fwd: Subject",
            typedText: "Hello", inReplyTo: nil, references: [],
            quoteSource: QuoteSource(
                author: Mailbox(name: "Alice", addr: "alice@example.com"),
                date: Date(timeIntervalSince1970: 1_757_500_000), subject: "Subject",
                to: [Mailbox(name: nil, addr: "user@example.com")], cc: [], html: "<div>x</div>", text: "x"),
            attachments: [], includeSignature: false)
    }

    // MARK: - load

    @MainActor
    func testLoadReadsSyncStateAndOutboxCounts() async throws {
        try await seedSyncState()
        try TestDatabase.seed(env.db, [TestDatabase.parsed(id: "m1", threadId: "t1", internalDate: Self.seedNow, labels: ["INBOX", "UNREAD"])])
        let job = sendJob()
        try await env.db.write { db in
            _ = try OutboxRepository.enqueueModify(
                db, threadId: "t1", delta: LabelDelta(remove: ["UNREAD"]), affectedMessageIds: ["m1"], now: Self.seedNow)
            let opId = try OutboxRepository.enqueueSend(db, job: job, now: Self.seedNow)
            try OutboxRepository.fail(db, opId: opId, error: "boom")
        }

        let model = SettingsModel(env: env, badge: StubBadge())
        await model.load()

        XCTAssertEqual(model.info.accountEmail, "max.mustermann@example.com")
        XCTAssertEqual(model.info.displayName, "Max Mustermann")
        XCTAssertEqual(model.info.historyId, "1234530")
        XCTAssertEqual(model.info.lastDeltaSyncAtMs, Self.seedNow)
        XCTAssertTrue(model.info.hasGmailSignature)
        XCTAssertEqual(model.info.pendingOps, 1)
        XCTAssertEqual(model.info.failedSends, 1)
        try InvariantChecks.assertAll(env.db)
    }

    @MainActor
    func testLoadWithEmptyDatabase() async {
        let model = SettingsModel(env: env, badge: StubBadge())
        await model.load()
        XCTAssertEqual(model.info, .empty)
        XCTAssertEqual(model.accountEmailLine, "—")
        XCTAssertEqual(model.lastSyncLine, "Never")
        XCTAssertFalse(model.info.hasGmailSignature)
    }

    @MainActor
    func testLoadIgnoresBlankSignature() async throws {
        try await seedSyncState(signature: "   ")
        let model = SettingsModel(env: env, badge: StubBadge())
        await model.load()
        XCTAssertFalse(model.info.hasGmailSignature)
    }

    // MARK: - badge

    @MainActor
    func testBadgeToggleOnGranted() async {
        let stub = StubBadge(grantResult: true)
        let model = SettingsModel(env: env, badge: stub)
        await model.setBadgeEnabled(true)
        let requests = await stub.requests
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(env.settings.snapshot.showBadge)
        XCTAssertEqual(model.badgeState, .idle)
    }

    @MainActor
    func testBadgeToggleOnDenied() async {
        let stub = StubBadge(grantResult: false)
        let model = SettingsModel(env: env, badge: stub)
        await model.setBadgeEnabled(true)
        XCTAssertFalse(env.settings.snapshot.showBadge)
        XCTAssertEqual(model.badgeState, .denied)
        let counts = await stub.badgeCounts
        XCTAssertTrue(counts.isEmpty)
    }

    @MainActor
    func testBadgeToggleOff() async {
        env.settings.update { $0.showBadge = true }
        let stub = StubBadge()
        let model = SettingsModel(env: env, badge: stub)
        await model.setBadgeEnabled(false)
        XCTAssertFalse(env.settings.snapshot.showBadge)
        let counts = await stub.badgeCounts
        XCTAssertEqual(counts, [0])
        XCTAssertEqual(model.badgeState, .idle)
        let requests = await stub.requests
        XCTAssertEqual(requests, 0)
    }

    @MainActor
    func testVerifyBadgeKeepsEnabled() async {
        env.settings.update { $0.showBadge = true }
        let stub = StubBadge(enabledResult: true)
        let model = SettingsModel(env: env, badge: stub)
        await model.verifyBadgeAuthorization()
        XCTAssertTrue(env.settings.snapshot.showBadge)
        XCTAssertEqual(model.badgeState, .idle)
        let checks = await stub.enabledChecks
        XCTAssertEqual(checks, 1)
    }

    @MainActor
    func testVerifyBadgeSelfOffWhenRevoked() async {
        env.settings.update { $0.showBadge = true }
        let stub = StubBadge(enabledResult: false)
        let model = SettingsModel(env: env, badge: stub)
        await model.verifyBadgeAuthorization()
        XCTAssertFalse(env.settings.snapshot.showBadge)
        XCTAssertEqual(model.badgeState, .denied)
        let counts = await stub.badgeCounts
        XCTAssertEqual(counts, [0])
    }

    @MainActor
    func testVerifyBadgeSkippedWhenOff() async {
        let stub = StubBadge()
        let model = SettingsModel(env: env, badge: stub)
        await model.verifyBadgeAuthorization()
        let checks = await stub.enabledChecks
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(model.badgeState, .idle)
    }

    // MARK: - derived strings

    @MainActor
    func testStatusLineMatrix() {
        let model = SettingsModel(env: env, badge: StubBadge())
        env.syncStatus.isOffline = true
        XCTAssertEqual(model.statusLine, "Offline")
        env.syncStatus.isOffline = false
        env.syncStatus.phase = .syncing
        XCTAssertEqual(model.statusLine, "Syncing…")
        env.syncStatus.phase = .initialSync
        XCTAssertEqual(model.statusLine, "First sync…")
        env.syncStatus.phase = .idle
        env.syncStatus.lastError = "Couldn't reach Gmail"
        XCTAssertEqual(model.statusLine, "Couldn't reach Gmail")
        env.syncStatus.lastError = nil
        XCTAssertEqual(model.statusLine, "Idle")
    }

    @MainActor
    func testLastSyncLinePrefersSyncStatus() async {
        let model = SettingsModel(env: env, badge: StubBadge())
        env.syncStatus.lastSyncAt = Date(timeIntervalSince1970: 1_757_600_000)
        let expected = Date(timeIntervalSince1970: 1_757_600_000).formatted(date: .abbreviated, time: .shortened)
        XCTAssertEqual(model.lastSyncLine, expected)
    }

    @MainActor
    func testLastSyncLineFallsBackToSyncState() async throws {
        try await seedSyncState(deltaAtMs: Self.seedNow)
        let model = SettingsModel(env: env, badge: StubBadge())
        await model.load()
        let expected =
            Date(timeIntervalSince1970: Double(Self.seedNow) / 1000).formatted(date: .abbreviated, time: .shortened)
        XCTAssertEqual(model.lastSyncLine, expected)
    }

    @MainActor
    func testVersionLine() {
        let model = SettingsModel(env: env, badge: StubBadge())
        XCTAssertEqual(model.versionLine, "0.1.0 (1)")
    }

    // MARK: - full resync & sign-out

    @MainActor
    func testFullResyncClearsHistoryIdAndReloads() async throws {
        try await seedSyncState(historyId: "1234530")
        let model = SettingsModel(env: env, badge: StubBadge())
        await model.load()
        XCTAssertEqual(model.info.historyId, "1234530")

        await model.fullResync()

        let stored = try await env.db.read { try SyncStateRepository.get($0, .historyId) }
        XCTAssertNil(stored)
        XCTAssertNil(model.info.historyId)
        XCTAssertFalse(model.isResyncing)
    }

    /// The `isResyncing` guard runs to completion on the main actor before the first `await`, so a second concurrent
    /// call is dropped. `lastRunReason` is not observable here (the test env is signed out, so the sync run bails
    /// before it is set), so the assertion is the observable end state.
    @MainActor
    func testFullResyncIsSingleFlight() async throws {
        try await seedSyncState(historyId: "1234530")
        let model = SettingsModel(env: env, badge: StubBadge())
        async let a: Void = model.fullResync()
        async let b: Void = model.fullResync()
        _ = await (a, b)
        XCTAssertFalse(model.isResyncing)
        let stored = try await env.db.read { try SyncStateRepository.get($0, .historyId) }
        XCTAssertNil(stored)
    }

    @MainActor
    func testSignOutIsIdempotent() async {
        let model = SettingsModel(env: env, badge: StubBadge())
        await model.signOut()
        await model.signOut()
        XCTAssertEqual(env.auth.state, .signedOut)
        XCTAssertFalse(model.isSigningOut)
    }
}

/// Records what `SettingsModel` asks of the badge system so the matrix can be checked deterministically.
private actor StubBadge: BadgeAuthorizing {
    private let grantResult: Bool
    private let enabledResult: Bool
    private(set) var requests = 0
    private(set) var enabledChecks = 0
    private(set) var badgeCounts: [Int] = []

    init(grantResult: Bool = false, enabledResult: Bool = false) {
        self.grantResult = grantResult
        self.enabledResult = enabledResult
    }

    func requestBadgeAuthorization() async -> Bool {
        requests += 1
        return grantResult
    }

    func isBadgeEnabled() async -> Bool {
        enabledChecks += 1
        return enabledResult
    }

    func setBadgeCount(_ count: Int) async {
        badgeCounts.append(count)
    }
}
