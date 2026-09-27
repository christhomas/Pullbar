import XCTest
@testable import pullbar

final class KeychainMigrationTests: XCTestCase {
    // Throwaway items: never the real "pullbar GitHub token" or PR Inbox's.
    private var service = ""
    private var legacy = ""

    override func setUp() {
        super.setUp()
        service = "pullbar-tests-\(UUID().uuidString)"
        legacy = "\(service)-legacy"
    }

    override func tearDown() {
        Keychain.deleteToken(service: service)
        Keychain.deleteToken(service: legacy)
        super.tearDown()
    }

    func testLegacyItemIsPRInboxs() {
        XCTAssertEqual(Keychain.legacyService, "PRInbox GitHub token")
    }

    func testMigrateMovesTheLegacyToken() throws {
        XCTAssertNil(Keychain.migrateToken(from: legacy, to: service), "nothing to move")
        XCTAssertNil(Keychain.readToken(service: service))

        do {
            try Keychain.writeToken(" ghp_old\n", service: legacy)
        } catch let error as KeychainError where error.status == errSecInteractionNotAllowed {
            throw XCTSkip("keychain is locked on this machine")
        }
        XCTAssertEqual(Keychain.migrateToken(from: legacy, to: service), "ghp_old")
        XCTAssertEqual(Keychain.readToken(service: service), "ghp_old")
        XCTAssertNil(Keychain.readToken(service: legacy), "the old item is deleted")
        XCTAssertNil(Keychain.migrateToken(from: legacy, to: service), "a second run moves nothing")
    }
}
