import XCTest
@testable import pullbar

final class GitHubErrorTests: XCTestCase {
    func testDescriptions() {
        XCTAssertEqual(GitHubError.noToken.errorDescription, "No GitHub token configured.")
        XCTAssertEqual(GitHubError.unauthorized.errorDescription, "GitHub rejected the token (401). Set a new one.")
        XCTAssertEqual(GitHubError.graphQL(["one", "two"]).errorDescription, "one\ntwo")
        XCTAssertEqual(GitHubError.malformed.errorDescription, "Unexpected response from GitHub.")
        XCTAssertEqual(GitHubError.http(502, "bad gateway").errorDescription, "GitHub returned HTTP 502: bad gateway")
    }

    func testHTTPBodyIsCutTo200Characters() throws {
        let body = String(repeating: "x", count: 500)
        let text = try XCTUnwrap(GitHubError.http(500, body).errorDescription)
        XCTAssertEqual(text, "GitHub returned HTTP 500: " + String(repeating: "x", count: 200))
    }
}

final class PassedCountTests: XCTestCase {
    private typealias Contexts = GQL.PullRequest.Rollup.Contexts

    private func contexts(runs: [String: Int] = [:], statuses: [String: Int] = [:]) -> Contexts {
        Contexts(
            totalCount: runs.values.reduce(0, +) + statuses.values.reduce(0, +),
            checkRunCountsByState: runs.map { .init(state: $0.key, count: $0.value) },
            statusContextCountsByState: statuses.map { .init(state: $0.key, count: $0.value) }
        )
    }

    func testCheckRunsPassWhenSuccessfulNeutralOrSkipped() {
        XCTAssertEqual(contexts(runs: ["SUCCESS": 3, "NEUTRAL": 2, "SKIPPED": 1]).passedCount, 6)
        let failing = ["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STALE", "IN_PROGRESS", "QUEUED", "PENDING"]
        XCTAssertEqual(contexts(runs: Dictionary(uniqueKeysWithValues: failing.map { ($0, 1) })).passedCount, 0)
    }

    func testStatusesPassOnlyOnSuccess() {
        XCTAssertEqual(contexts(statuses: ["SUCCESS": 2, "PENDING": 1, "FAILURE": 1, "ERROR": 1, "EXPECTED": 1]).passedCount, 2)
    }

    func testRunsAndStatusesAddUp() {
        XCTAssertEqual(contexts(runs: ["SUCCESS": 4, "FAILURE": 1], statuses: ["SUCCESS": 2]).passedCount, 6)
    }

    func testNoChecks() {
        XCTAssertEqual(contexts().passedCount, 0)
    }
}

final class GitHubClientTests: XCTestCase {
    private func client(token: String = "secret-token") -> GitHubClient {
        GitHubClient(token: token, session: StubGitHub.session())
    }

    // MARK: Requests

    func testRequestShape() async throws {
        StubGitHub.install { _ in (200, searchResponse(nodes: [])) }
        _ = try await client().searchPullRequests("review-requested:@me")

        let request = try XCTUnwrap(StubGitHub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/graphql")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Authorization"], "Bearer secret-token")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["User-Agent"], "pullbar-menubar")
        XCTAssertTrue(request.query.contains("query PullbarSearch"))
        XCTAssertEqual(request.variables["q"] as? String, "is:pr review-requested:@me")
        XCTAssertEqual(request.variables["first"] as? Int, 50)
        XCTAssertNil(request.variables["after"], "no cursor on the first page")
    }

    func testPagingFollowsTheCursor() async throws {
        StubGitHub.install { request in
            if request.variables["after"] == nil {
                return (200, searchResponse(nodes: [prNode(id: "A", number: 1)], hasNextPage: true, endCursor: "CURSOR1"))
            }
            XCTAssertEqual(request.variables["after"] as? String, "CURSOR1")
            return (200, searchResponse(nodes: [prNode(id: "B", number: 2)]))
        }
        let result = try await client().searchPullRequests("author:@me")
        XCTAssertEqual(StubGitHub.requests.count, 2)
        XCTAssertEqual(Set(result.pullRequests.map(\.id)), ["A", "B"])
    }

    func testPagingStopsAtMaxPages() async throws {
        StubGitHub.install { request in
            let page = (request.variables["after"] as? String).map { Int($0)! + 1 } ?? 1
            return (200, searchResponse(nodes: [prNode(id: "PR\(page)", number: page)], hasNextPage: true, endCursor: "\(page)"))
        }
        let result = try await client().searchPullRequests("author:@me", maxPages: 3)
        XCTAssertEqual(StubGitHub.requests.count, 3)
        XCTAssertEqual(result.pullRequests.count, 3)
    }

    func testPagingStopsWhenThereIsNoCursor() async throws {
        StubGitHub.install { _ in (200, searchResponse(nodes: [prNode()], hasNextPage: true, endCursor: nil)) }
        _ = try await client().searchPullRequests("author:@me")
        XCTAssertEqual(StubGitHub.requests.count, 1)
    }

    // MARK: Mapping GitHub's data

    func testFullPullRequestIsMapped() async throws {
        let node = prNode(
            id: "PR_kw", number: 42, title: "Fix it", repository: "acme/api", author: "mona",
            isDraft: true, updatedAt: "2026-03-10T12:00:00Z", mergeable: "CONFLICTING",
            reviewDecision: "CHANGES_REQUESTED", comments: 7,
            rollup: rollup(state: "FAILURE", contexts: [
                checkRun("SUCCESS"), checkRun("SKIPPED"), checkRun("FAILURE"), statusContext("SUCCESS"), statusContext("PENDING"),
            ])
        )
        StubGitHub.install { _ in (200, searchResponse(viewer: "octocat", nodes: [node])) }
        let result = try await client().searchPullRequests("q")

        XCTAssertEqual(result.viewerLogin, "octocat")
        let pr = try XCTUnwrap(result.pullRequests.first)
        XCTAssertEqual(pr.id, "PR_kw")
        XCTAssertEqual(pr.number, 42)
        XCTAssertEqual(pr.title, "Fix it")
        XCTAssertEqual(pr.url.absoluteString, "https://github.com/acme/api/pull/42")
        XCTAssertTrue(pr.isDraft)
        XCTAssertEqual(pr.updatedAt, referenceDate)
        XCTAssertEqual(pr.author, "mona")
        XCTAssertEqual(pr.repository, "acme/api")
        XCTAssertEqual(pr.reviewDecision, .changesRequested)
        XCTAssertEqual(pr.mergeable, .conflicting)
        XCTAssertEqual(pr.commentCount, 7)
        XCTAssertEqual(pr.checks, Checks(state: .failure, total: 5, passed: 3))
    }

    func testManyChecksAreCountedExactlyInOneRequest() async throws {
        // More checks than any single page of a list would hold.
        let contexts = Array(repeating: checkRun("SUCCESS"), count: 140)
            + Array(repeating: checkRun("FAILURE"), count: 3)
            + Array(repeating: statusContext("SUCCESS"), count: 7)
        StubGitHub.install { _ in (200, searchResponse(nodes: [prNode(rollup: rollup(state: "FAILURE", contexts: contexts))])) }
        let pr = try await XCTUnwrapAsync(await client().searchPullRequests("q").pullRequests.first)
        XCTAssertEqual(pr.checks, Checks(state: .failure, total: 150, passed: 147))
        XCTAssertEqual(StubGitHub.requests.count, 1, "no extra requests to count checks")
    }

    func testTheQueryAsksForCountsNotAListOfChecks() async throws {
        StubGitHub.install { _ in (200, searchResponse(nodes: [])) }
        _ = try await client().searchPullRequests("q")
        let query = try XCTUnwrap(StubGitHub.requests.first?.query)
        XCTAssertTrue(query.contains("contexts(first: 0)"))
        XCTAssertTrue(query.contains("checkRunCountsByState { state count }"))
        XCTAssertTrue(query.contains("statusContextCountsByState { state count }"))
    }

    func testMissingOptionalFieldsGetDefaults() async throws {
        let node = prNode(author: nil, isDraft: nil, mergeable: nil, reviewDecision: nil, comments: nil, rollup: nil)
        StubGitHub.install { _ in (200, searchResponse(nodes: [node])) }
        let pr = try await XCTUnwrapAsync(await client().searchPullRequests("q").pullRequests.first)
        XCTAssertEqual(pr.author, "ghost")
        XCTAssertFalse(pr.isDraft)
        XCTAssertEqual(pr.mergeable, .unknown)
        XCTAssertNil(pr.reviewDecision)
        XCTAssertEqual(pr.commentCount, 0)
        XCTAssertNil(pr.checks)
    }

    func testUnknownValuesFallBack() async throws {
        let node = prNode(mergeable: "SOMETHING_NEW", reviewDecision: "SOMETHING_NEW",
                          rollup: rollup(state: "SOMETHING_NEW", contexts: []))
        StubGitHub.install { _ in (200, searchResponse(nodes: [node])) }
        let pr = try await XCTUnwrapAsync(await client().searchPullRequests("q").pullRequests.first)
        XCTAssertEqual(pr.mergeable, .unknown)
        XCTAssertNil(pr.reviewDecision)
        XCTAssertEqual(pr.checks?.state, .pending)
        XCTAssertEqual(pr.checks?.total, 0)
    }

    func testNodesThatAreNotUsablePullRequestsAreDropped() async throws {
        var missingTitle = prNode(id: "no-title")
        missingTitle.removeValue(forKey: "title")
        let nodes: [Any] = [NSNull(), [String: Any](), missingTitle, prNode(id: "good")]
        StubGitHub.install { _ in (200, searchResponse(nodes: nodes)) }
        let result = try await client().searchPullRequests("q")
        XCTAssertEqual(result.pullRequests.map(\.id), ["good"])
    }

    // MARK: Errors

    func testUnauthorized() async {
        StubGitHub.install { _ in (401, "Bad credentials") }
        await assertThrows(GitHubError.unauthorized) { try await self.client().searchPullRequests("q") }
    }

    func testHTTPError() async {
        StubGitHub.install { _ in (503, "maintenance") }
        do {
            _ = try await client().searchPullRequests("q")
            XCTFail("expected an error")
        } catch GitHubError.http(let code, let body) {
            XCTAssertEqual(code, 503)
            XCTAssertEqual(body, "maintenance")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testGraphQLErrorsWithoutData() async {
        StubGitHub.install { _ in (200, ["data": NSNull(), "errors": [["message": "first"], ["message": "second"]]]) }
        do {
            _ = try await client().searchPullRequests("q")
            XCTFail("expected an error")
        } catch GitHubError.graphQL(let messages) {
            XCTAssertEqual(messages, ["first", "second"])
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testGraphQLErrorsWithDataStillReturnTheData() async throws {
        var response = searchResponse(nodes: [prNode(id: "partial")])
        response["errors"] = [["message": "one field failed"]]
        StubGitHub.install { _ in (200, response) }
        let result = try await client().searchPullRequests("q")
        XCTAssertEqual(result.pullRequests.map(\.id), ["partial"])
    }

    func testMissingDataIsMalformed() async {
        StubGitHub.install { _ in (200, ["data": NSNull()]) }
        await assertThrows(GitHubError.malformed) { try await self.client().searchPullRequests("q") }
    }

    func testUndecodableBodyThrows() async {
        StubGitHub.install { _ in (200, "not json") }
        do {
            _ = try await client().searchPullRequests("q")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
    }

    // MARK: Helpers

    private func assertThrows(
        _ expected: GitHubError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @escaping () async throws -> Any
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as GitHubError {
            XCTAssertEqual(error.errorDescription, expected.errorDescription, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
