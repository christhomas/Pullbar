import Foundation

/// Runs the three searches that github.com/pulls/inbox is made of and folds
/// them into sections.
struct InboxService {
    let client: GitHubClient

    func fetch(window: UpdatedWindow) async throws -> Inbox {
        let base = ["is:open", "archived:false", "sort:updated-desc", window.searchQualifier]
            .compactMap { $0 }
            .joined(separator: " ")

        async let requested = client.searchPullRequests("\(base) review-requested:@me")
        async let direct = client.searchPullRequests("\(base) user-review-requested:@me")
        async let authored = client.searchPullRequests("\(base) author:@me")

        let (r, d, a) = try await (requested, direct, authored)
        return Inbox.build(
            reviewRequested: r.pullRequests,
            userReviewRequested: d.pullRequests,
            authored: a.pullRequests,
            viewerLogin: a.viewerLogin,
            apiUsage: Self.apiUsage(of: [r, d, a])
        )
    }

    /// The budget left after this refresh (the lowest the searches saw) and
    /// what the refresh cost in total; nil when GitHub reported no budget.
    static func apiUsage(of results: [GitHubClient.SearchResult]) -> APIUsage? {
        guard let lowest = results.compactMap(\.rateLimit).min(by: { $0.remaining < $1.remaining }) else { return nil }
        return APIUsage(
            limit: lowest.limit,
            remaining: lowest.remaining,
            resetAt: lowest.resetAt,
            lastRefreshCost: results.reduce(0) { $0 + $1.cost },
            lastRefreshRequests: results.reduce(0) { $0 + $1.requests }
        )
    }
}
