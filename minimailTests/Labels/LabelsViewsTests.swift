import GRDB
import MailCore
import SwiftUI
import UIKit
import XCTest

@testable import minimail

/// Spec 12 §7.2. Pure row/footer/colour helpers plus hosting smoke tests for `LabelsScreen`.
nonisolated final class LabelsViewsTests: XCTestCase {
    private var env: AppEnvironment!
    private let fixed = Date(timeIntervalSince1970: 1_757_500_000)

    @MainActor override func setUp() async throws {
        env = AppEnvironment(testing: true)
    }

    @MainActor override func tearDown() async throws {
        await env.sync.cancelAll()
        await env.outbox.cancelAll()
        env = nil
    }

    private func label(
        id: String, name: String, type: String, labelListVisibility: String? = nil,
        backgroundColor: String? = nil, textColor: String? = nil, threadsUnread: Int? = nil, sortOrder: Int = 1000
    ) -> LabelRecord {
        LabelRecord(
            id: id, name: name, type: type, labelListVisibility: labelListVisibility, messageListVisibility: "show",
            textColor: textColor, backgroundColor: backgroundColor, messagesUnread: nil, threadsUnread: threadsUnread,
            threadsTotal: nil, countsFetchedAt: nil, sortOrder: sortOrder, viewFetchedAt: nil, viewNextPageToken: nil)
    }

    // MARK: - pure helpers

    func testDisplayNamePureFunction() {
        XCTAssertEqual(LabelsModel.displayName(for: label(id: "STARRED", name: "STARRED", type: "system")), "Starred")
        XCTAssertEqual(LabelsModel.displayName(for: label(id: "SENT", name: "SENT", type: "system")), "Sent")
        XCTAssertEqual(
            LabelsModel.displayName(for: label(id: "CATEGORY_PROMOTIONS", name: "CATEGORY_PROMOTIONS", type: "system")),
            "CATEGORY_PROMOTIONS")
        XCTAssertEqual(LabelsModel.displayName(for: label(id: "Label_9", name: "SENT", type: "user")), "SENT")
        XCTAssertEqual(
            LabelsModel.displayName(for: label(id: "Label_12", name: "Customers/ACME", type: "user")),
            "Customers/ACME")
    }

    func testSymbolPureFunction() {
        XCTAssertEqual(LabelsModel.symbol(for: label(id: "IMPORTANT", name: "IMPORTANT", type: "system")), "bookmark")
        XCTAssertEqual(LabelsModel.symbol(for: label(id: "TRASH", name: "TRASH", type: "system")), "trash")
        XCTAssertEqual(LabelsModel.symbol(for: label(id: "CHAT", name: "CHAT", type: "system")), "tag")
        XCTAssertNil(LabelsModel.symbol(for: label(id: "Label_12", name: "x", type: "user", backgroundColor: "#4a86e8")))
        XCTAssertEqual(LabelsModel.symbol(for: label(id: "Label_13", name: "y", type: "user")), "tag")
    }

    func testCountTextPureFunction() {
        XCTAssertNil(LabelsModel.countText(nil))
        XCTAssertNil(LabelsModel.countText(0))
        XCTAssertNil(LabelsModel.countText(-3))
        XCTAssertEqual(LabelsModel.countText(1), "1")
        XCTAssertEqual(LabelsModel.countText(999), "999")
        XCTAssertEqual(LabelsModel.countText(1000), "999+")
    }

    func testRowProjection() {
        let r = LabelsModel.row(
            for: label(
                id: "Label_12", name: "Customers/ACME", type: "user", backgroundColor: "#4a86e8", threadsUnread: 2))
        XCTAssertEqual(r.id, "Label_12")
        XCTAssertEqual(r.title, "Customers/ACME")
        XCTAssertEqual(r.countText, "2")
        XCTAssertNil(r.symbol)
        XCTAssertEqual(r.colorHex, "#4a86e8")
        XCTAssertEqual(r.scope, .label(id: "Label_12"))
        XCTAssertEqual(r.accessibilityLabel, "Customers/ACME")
        XCTAssertEqual(r.accessibilityValue, "2 unread")
    }

    func testMailboxRowsProjection() {
        let rows = LabelsModel.mailboxRows(inboxUnread: 12, today: 0)
        XCTAssertEqual(rows.map(\.id), ["mailbox.inbox", "mailbox.today"])
        XCTAssertEqual(rows.map(\.title), ["Inbox", "Today"])
        XCTAssertEqual(rows.map(\.symbol), ["tray", "sun.max"])
        XCTAssertEqual(rows.map(\.countText), ["12", nil])
        XCTAssertEqual(rows.map(\.accessibilityValue), ["12 unread", nil])
        XCTAssertEqual(rows.map(\.scope), [.inbox, .today])
    }

    func testFooterPureFunction() {
        let now = fixed
        func f(_ at: Date?, _ off: Bool = false, _ refreshing: Bool = false) -> String {
            LabelsModel.footer(countsFetchedAt: at, now: now, isOffline: off, isRefreshing: refreshing)
        }
        XCTAssertEqual(f(nil), "Counts from Gmail · not loaded yet")
        XCTAssertEqual(f(now - 10), "Counts from Gmail · updated just now")
        XCTAssertEqual(f(now - 180), "Counts from Gmail · updated 3 min ago")
        XCTAssertEqual(f(now - 7_200), "Counts from Gmail · updated 2 h ago")
        XCTAssertEqual(f(now - 4 * 86_400), "Counts from Gmail · updated 4 d ago")
        XCTAssertEqual(f(now - 10, true, false), "Counts from Gmail · offline")
        XCTAssertEqual(f(nil, true, true), "Updating counts from Gmail…")
        XCTAssertEqual(f(now + 60), "Counts from Gmail · updated just now")  // negative age clamped
    }

    func testLabelChipStillParsesHexAfterMove() {
        XCTAssertNotNil(LabelChip.color(hex: "#ff0000"))
        XCTAssertNotNil(LabelChip.color(hex: "#FF0000"))
        XCTAssertNil(LabelChip.color(hex: "#ff000"))
        XCTAssertNil(LabelChip.color(hex: "ff0000"))
        XCTAssertNil(LabelChip.color(hex: "#gg0000"))
        XCTAssertNil(LabelChip.color(hex: nil))
        var b: CGFloat = 0
        UIColor(LabelChip.color(hex: "#0000ff")!).getRed(nil, green: nil, blue: &b, alpha: nil)
        XCTAssertEqual(b, 1, accuracy: 0.01)
    }

    // MARK: - hosting

    @MainActor
    private func host(_ view: some View) -> UIView {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return controller.view
    }

    private func containsCollectionOrTable(_ view: UIView) -> Bool {
        if view is UICollectionView || view is UITableView { return true }
        return view.subviews.contains { containsCollectionOrTable($0) }
    }

    @MainActor
    func testLabelColorDotFallback() {
        _ = host(LabelColorDot(colorHex: nil).environment(env.theme))
        _ = host(LabelColorDot(colorHex: "#4a86e8").environment(env.theme))
        XCTAssertEqual(LabelColorDot.diameter, 10)
    }

    @MainActor
    func testLabelsScreenHostsSeededLabels() throws {
        try TestDatabase.seedLabels(env.db, TestDatabase.sampleLabels)
        let view = host(
            LabelsScreen(onSelect: { _ in }).environment(env).environment(env.theme).environment(env.settings))
        XCTAssertFalse(view.subviews.isEmpty)
        XCTAssertTrue(containsCollectionOrTable(view))
        XCTAssertFalse(env.deferredWorkStarted)
    }

    @MainActor
    func testLabelsScreenHostsEmptyDatabase() {
        let view = host(
            LabelsScreen(onSelect: { _ in }).environment(env).environment(env.theme).environment(env.settings))
        XCTAssertFalse(view.subviews.isEmpty)
    }

    @MainActor
    func testLabelsScreenInSheetHosting() {
        struct Host: View {
            @State var shown = true
            var body: some View {
                Color.clear.sheet(isPresented: $shown) { LabelsScreen(onSelect: { _ in }) }
            }
        }
        _ = host(Host().environment(env).environment(env.theme).environment(env.settings))
    }
}
