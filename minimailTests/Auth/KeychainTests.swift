import XCTest

@testable import minimail

nonisolated final class KeychainTests: XCTestCase {

    /// Unique account per test; cleaned before and after so a crashed run cannot poison the next.
    private func account(_ fn: String = #function) -> String { "test.\(fn)" }

    private func clean(_ accounts: String...) {
        for account in accounts { try? Keychain.delete(account: account) }
    }

    func testServiceConstant() {
        XCTAssertEqual(Keychain.service, "com.minimail")
    }

    func testGetMissingIsNil() throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        XCTAssertNil(try Keychain.get(account: a))
        XCTAssertFalse(Keychain.exists(account: a))
    }

    func testSetGetRoundTrip() throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        try Keychain.set(Data("hello".utf8), account: a)
        XCTAssertEqual(try Keychain.get(account: a), Data("hello".utf8))
        XCTAssertTrue(Keychain.exists(account: a))
    }

    func testOverwriteReplaces() throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        try Keychain.set(Data("a".utf8), account: a)
        try Keychain.set(Data("bb".utf8), account: a)
        XCTAssertEqual(try Keychain.get(account: a), Data("bb".utf8))
    }

    func testDeleteRemoves() throws {
        let a = account()
        clean(a)
        try Keychain.set(Data("x".utf8), account: a)
        try Keychain.delete(account: a)
        XCTAssertNil(try Keychain.get(account: a))
        XCTAssertFalse(Keychain.exists(account: a))
    }

    func testDeleteMissingDoesNotThrow() {
        let a = account()
        clean(a)
        XCTAssertNoThrow(try Keychain.delete(account: a))
    }

    func testLargePayload() throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        let blob = Data(repeating: 0xAB, count: 65_536)
        try Keychain.set(blob, account: a)
        let read = try Keychain.get(account: a)
        XCTAssertEqual(read, blob)
        XCTAssertEqual(read?.count, 65_536)
    }

    func testAccountsAreIsolated() throws {
        let a = account() + ".A"
        let b = account() + ".B"
        clean(a, b)
        defer { clean(a, b) }
        try Keychain.set(Data("x".utf8), account: a)
        try Keychain.set(Data("y".utf8), account: b)
        XCTAssertEqual(try Keychain.get(account: a), Data("x".utf8))
        XCTAssertEqual(try Keychain.get(account: b), Data("y".utf8))
        try Keychain.delete(account: a)
        XCTAssertNil(try Keychain.get(account: a))
        XCTAssertEqual(try Keychain.get(account: b), Data("y".utf8))
    }

    func testExistsIsFast() throws {
        let a = account()
        clean(a)
        defer { clean(a) }
        try Keychain.set(Data("x".utf8), account: a)
        measure { _ = Keychain.exists(account: a) }
    }
}
