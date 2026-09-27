import XCTest
@testable import pullbar

final class PageSizeTests: XCTestCase {
    func testSearchAsksForGitHubsLargestPage() async throws {
        StubGitHub.install { _ in (200, searchResponse(nodes: [])) }
        _ = try await GitHubClient(token: "t", session: StubGitHub.session()).searchPullRequests("q")
        XCTAssertEqual(StubGitHub.requests.first?.variables["first"] as? Int, 100)
    }
}
