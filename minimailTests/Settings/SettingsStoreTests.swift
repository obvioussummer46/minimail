import MailCore
import XCTest

@testable import minimail

nonisolated final class SettingsStoreTests: XCTestCase {

    @MainActor
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "minimailTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func makeStore(seededWith json: String, _ name: String = #function) -> SettingsStore {
        let defaults = freshDefaults(name)
        defaults.set(Data(json.utf8), forKey: SettingsStore.key)
        return SettingsStore(defaults: defaults)
    }

    @MainActor
    func testMissingKeyGivesDefaults() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings, Settings())
        XCTAssertNil(defaults.data(forKey: SettingsStore.key), "init must not write")
    }

    @MainActor
    func testUpdateWritesSynchronouslyAndSortedKeys() throws {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        store.update { $0.themeChoice = .dark }

        let data = try XCTUnwrap(defaults.data(forKey: SettingsStore.key))
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            ##"{"composeStyle":{"colorHex":"#000000","family":"helvetica","sizePx":14},"inboxPageSize":100,"##
                + ##""loadRemoteImages":false,"markReadOnOpen":true,"plainTextBodies":false,"##
                + ##""previewLineCount":2,"schemaVersion":1,"##
                + ##""showBadge":false,"signatureEnabled":true,"signatureHTML":"","themeChoice":"dark"}"##
        )
        XCTAssertEqual(SettingsStore(defaults: defaults).settings.themeChoice, .dark)
    }

    @MainActor
    func testPlainTextBodiesDefaultsOffAndDecodes() {
        XCTAssertFalse(Settings().plainTextBodies)
        XCTAssertTrue(makeStore(seededWith: #"{"plainTextBodies":true}"#).settings.plainTextBodies)
        // Absent from an older install's payload: the default stands rather than throwing the decode.
        XCTAssertFalse(makeStore(seededWith: #"{"markReadOnOpen":false}"#).settings.plainTextBodies)
    }

    @MainActor
    func testCorruptDataFallsBack() {
        XCTAssertEqual(makeStore(seededWith: "not json").settings, Settings())
    }

    @MainActor
    func testPartialJSON() {
        let settings = makeStore(seededWith: #"{"themeChoice":"dark"}"#).settings
        XCTAssertEqual(settings.themeChoice, .dark)
        XCTAssertEqual(settings.inboxPageSize, 100)
        XCTAssertEqual(settings.composeStyle, ComposeStyle())
    }

    @MainActor
    func testUnknownThemeChoice() {
        XCTAssertEqual(makeStore(seededWith: #"{"themeChoice":"sepia"}"#).settings.themeChoice, .system)
    }

    @MainActor
    func testUnknownKeysIgnored() {
        let settings = makeStore(seededWith: #"{"unknownKey":1,"markReadOnOpen":false}"#).settings
        XCTAssertFalse(settings.markReadOnOpen)
    }

    @MainActor
    func testClampInboxPageSize() {
        XCTAssertEqual(makeStore(seededWith: #"{"inboxPageSize":999}"#).settings.inboxPageSize, 200)
        XCTAssertEqual(makeStore(seededWith: #"{"inboxPageSize":1}"#, "low").settings.inboxPageSize, 50)

        let store = SettingsStore(defaults: freshDefaults())
        store.update { $0.inboxPageSize = 0 }
        XCTAssertEqual(store.settings.inboxPageSize, 50)
    }

    @MainActor
    func testClampPreviewLineCount() {
        XCTAssertEqual(makeStore(seededWith: #"{"previewLineCount":99}"#).settings.previewLineCount, 6)
        XCTAssertEqual(makeStore(seededWith: #"{"previewLineCount":0}"#, "low").settings.previewLineCount, 1)

        let store = SettingsStore(defaults: freshDefaults())
        store.update { $0.previewLineCount = 42 }
        XCTAssertEqual(store.settings.previewLineCount, 6)
    }

    @MainActor
    func testNestedComposeStyleFailureIsolated() {
        let settings = makeStore(seededWith: #"{"composeStyle":{"sizePx":"big"},"showBadge":true}"#).settings
        XCTAssertEqual(settings.composeStyle, ComposeStyle())
        XCTAssertTrue(settings.showBadge)
    }

    @MainActor
    func testComposeStyleNormalisedThroughUpdate() {
        let store = SettingsStore(defaults: freshDefaults())
        store.update {
            $0.composeStyle.sizePx = 99
            $0.composeStyle.colorHex = "#ABCDEF"
        }
        XCTAssertEqual(store.settings.composeStyle.sizePx, 18)
        XCTAssertEqual(store.settings.composeStyle.colorHex, "#abcdef")
    }

    @MainActor
    func testScalarTypeMismatchFallsBack() {
        XCTAssertEqual(makeStore(seededWith: #"{"markReadOnOpen":"yes"}"#).settings, Settings())
    }

    @MainActor
    func testLastSignedInEmailTrimmed() throws {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)

        store.update { $0.lastSignedInEmail = "  " }
        XCTAssertNil(store.settings.lastSignedInEmail)
        let blankJSON = String(decoding: try XCTUnwrap(defaults.data(forKey: SettingsStore.key)), as: UTF8.self)
        XCTAssertFalse(blankJSON.contains("lastSignedInEmail"))

        store.update { $0.lastSignedInEmail = " a@b.de " }
        XCTAssertEqual(store.settings.lastSignedInEmail, "a@b.de")
    }

    @MainActor
    func testSnapshotIsCopy() {
        let store = SettingsStore(defaults: freshDefaults())
        let snapshot = store.snapshot
        store.update { $0.showBadge = true }
        XCTAssertFalse(snapshot.showBadge)
        XCTAssertTrue(store.settings.showBadge)
    }
}
