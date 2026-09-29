import AppKit
import XCTest
@testable import pullbar

final class InboxServiceTests: XCTestCase {
    /// Answers each of the three inbox searches with its own pull requests.
    private func installInbox() {
        StubGitHub.install { request in
            let q = request.variables["q"] as? String ?? ""
            if q.hasSuffix(" user-review-requested:@me") {
                return (200, searchResponse(viewer: "direct-viewer", nodes: [prNode(id: "direct")]))
            }
            if q.hasSuffix(" review-requested:@me") {
                return (200, searchResponse(viewer: "requested-viewer", nodes: [prNode(id: "direct"), prNode(id: "team")]))
            }
            if q.hasSuffix(" author:@me") {
                return (200, searchResponse(viewer: "octocat", nodes: [prNode(id: "mine", isDraft: true)]))
            }
            return (500, "unexpected query \(q)")
        }
    }

    func testFetchRunsTheThreeInboxSearches() async throws {
        installInbox()
        let service = InboxService(client: GitHubClient(token: "t", session: StubGitHub.session()))
        _ = try await service.fetch(window: .all)

        let queries = StubGitHub.requests.compactMap { $0.variables["q"] as? String }.sorted()
        XCTAssertEqual(queries, [
            "is:pr is:open archived:false sort:updated-desc author:@me",
            "is:pr is:open archived:false sort:updated-desc review-requested:@me",
            "is:pr is:open archived:false sort:updated-desc user-review-requested:@me",
        ])
    }

    func testFetchAddsTheUpdatedFilter() async throws {
        installInbox()
        let service = InboxService(client: GitHubClient(token: "t", session: StubGitHub.session()))
        _ = try await service.fetch(window: .week)
        let qualifier = try XCTUnwrap(UpdatedWindow.week.searchQualifier)
        for request in StubGitHub.requests {
            let q = request.variables["q"] as? String ?? ""
            XCTAssertTrue(q.contains(" \(qualifier) "), q)
        }
    }

    func testFetchSortsResultsIntoSections() async throws {
        installInbox()
        let service = InboxService(client: GitHubClient(token: "t", session: StubGitHub.session()))
        let inbox = try await service.fetch(window: .month)
        XCTAssertEqual(inbox.pullRequests(in: .needsYourReview).map(\.id), ["direct"])
        XCTAssertEqual(inbox.pullRequests(in: .needsTeamsReview).map(\.id), ["team"])
        XCTAssertEqual(inbox.pullRequests(in: .yourDrafts).map(\.id), ["mine"])
        // The viewer comes from the authored search.
        XCTAssertEqual(inbox.viewerLogin, "octocat")
    }

    func testFetchFailsWhenAnySearchFails() async {
        StubGitHub.install { request in
            let q = request.variables["q"] as? String ?? ""
            return q.hasSuffix("author:@me") ? (401, "no") : (200, searchResponse(nodes: []))
        }
        let service = InboxService(client: GitHubClient(token: "t", session: StubGitHub.session()))
        do {
            _ = try await service.fetch(window: .all)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? GitHubError)?.errorDescription, GitHubError.unauthorized.errorDescription)
        }
    }
}

final class KeychainTests: XCTestCase {
    private var service = ""

    override func setUp() {
        super.setUp()
        // A throwaway item: never the real "pullbar GitHub token".
        service = "pullbar-tests-\(UUID().uuidString)"
    }

    override func tearDown() {
        Keychain.deleteToken(service: service)
        super.tearDown()
    }

    func testRealItemIsNotTheTestItem() {
        XCTAssertEqual(Keychain.defaultService, "pullbar GitHub token")
        XCTAssertNotEqual(service, Keychain.defaultService)
    }

    func testWriteReadOverwriteDelete() throws {
        XCTAssertNil(Keychain.readToken(service: service))
        do {
            try Keychain.writeToken("first", service: service)
        } catch let error as KeychainError where error.status == errSecInteractionNotAllowed {
            throw XCTSkip("keychain is locked on this machine")
        }
        XCTAssertEqual(Keychain.readToken(service: service), "first")

        try Keychain.writeToken("second", service: service)
        XCTAssertEqual(Keychain.readToken(service: service), "second")

        Keychain.deleteToken(service: service)
        XCTAssertNil(Keychain.readToken(service: service))
    }

    func testStoredWhitespaceIsTrimmedOnRead() throws {
        try Keychain.writeToken("  ghp_abc \n", service: service)
        XCTAssertEqual(Keychain.readToken(service: service), "ghp_abc")
        try Keychain.writeToken("   ", service: service)
        XCTAssertNil(Keychain.readToken(service: service))
    }

    func testNormalizedToken() {
        XCTAssertEqual(Keychain.normalizedToken("ghp_x"), "ghp_x")
        XCTAssertEqual(Keychain.normalizedToken("\t ghp_x \n"), "ghp_x")
        XCTAssertNil(Keychain.normalizedToken(""))
        XCTAssertNil(Keychain.normalizedToken(" \n"))
    }

    func testErrorDescription() {
        XCTAssertFalse((KeychainError(status: errSecItemNotFound).errorDescription ?? "").isEmpty)
    }
}

final class TokenProviderTests: XCTestCase {
    func testReadsAndTrimsTheCommandOutput() async {
        let token = await TokenProvider.fromGhCLI(command: "printf '  gho_token \\n'")
        XCTAssertEqual(token, "gho_token")
    }

    func testFailingCommandGivesNoToken() async {
        let token = await TokenProvider.fromGhCLI(command: "echo gho_token; exit 1")
        XCTAssertNil(token)
    }

    func testEmptyOutputGivesNoToken() async {
        let token = await TokenProvider.fromGhCLI(command: "printf ''")
        XCTAssertNil(token)
    }

    func testPasteShortcut() {
        XCTAssertTrue(TokenTextField.isPaste(flags: .command, characters: "v"))
        XCTAssertTrue(TokenTextField.isPaste(flags: .command, characters: "V"))
        // Caps Lock, Fn, and the keypad flag are not modifiers: they must not stop paste.
        XCTAssertTrue(TokenTextField.isPaste(flags: [.command, .capsLock], characters: "v"))
        XCTAssertTrue(TokenTextField.isPaste(flags: [.command, .function, .numericPad], characters: "v"))
        XCTAssertFalse(TokenTextField.isPaste(flags: [.command, .control], characters: "v"))

        XCTAssertFalse(TokenTextField.isPaste(flags: [.command, .shift], characters: "v"))
        XCTAssertFalse(TokenTextField.isPaste(flags: [.command, .option], characters: "v"))
        XCTAssertFalse(TokenTextField.isPaste(flags: [], characters: "v"))
        XCTAssertFalse(TokenTextField.isPaste(flags: .command, characters: "c"))
        XCTAssertFalse(TokenTextField.isPaste(flags: .command, characters: nil))
    }
}
