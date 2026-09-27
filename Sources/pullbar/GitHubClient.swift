import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum GitHubError: LocalizedError {
    case noToken
    case unauthorized
    case http(Int, String)
    case graphQL([String])
    case malformed
    /// The GraphQL budget is used up until `resetAt` (nil when GitHub did not say).
    case rateLimited(resetAt: Date?)

    var errorDescription: String? {
        switch self {
        case .noToken: return "No GitHub token configured."
        case .unauthorized: return "GitHub rejected the token (401). Set a new one."
        case .http(let code, let body): return "GitHub returned HTTP \(code): \(body.prefix(200))"
        case .graphQL(let messages): return messages.joined(separator: "\n")
        case .malformed: return "Unexpected response from GitHub."
        case .rateLimited(let resetAt):
            guard let resetAt else { return "GitHub API limit reached. Try again later." }
            return "GitHub API limit reached. It resets at \(resetAt.formatted(date: .omitted, time: .shortened))."
        }
    }
}

/// Minimal GitHub GraphQL client: one `search` per inbox query. Check results
/// come as GitHub's per-state counts, so no extra requests are needed however
/// many checks a pull request has.
final class GitHubClient: @unchecked Sendable {
    private let token: String
    private let endpoint = URL(string: "https://api.github.com/graphql")!
    private let session: URLSession
    private let decoder: JSONDecoder

    /// `session` is for tests, which answer requests with a stub.
    init(token: String, session: URLSession? = nil) {
        self.token = token
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config)
        }
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Public

    struct SearchResult {
        let viewerLogin: String
        let pullRequests: [PullRequest]
        /// GitHub's budget after the last page, and what all pages cost.
        var rateLimit: GQL.RateLimit? = nil
        var cost = 0
        var requests = 0
    }

    /// Runs a GitHub issue search (`is:pr` is added) and returns all open PRs
    /// it finds, paging up to `maxPages` × 100 (100 is GitHub's maximum page size,
    /// and costs no more than 50).
    func searchPullRequests(_ query: String, maxPages: Int = 4) async throws -> SearchResult {
        var cursor: String? = nil
        var raw: [GQL.PullRequest] = []
        var viewer = ""
        var rateLimit: GQL.RateLimit?
        var cost = 0
        var requests = 0
        for _ in 0..<maxPages {
            let vars: [String: Any?] = ["q": "is:pr \(query)", "first": 100, "after": cursor]
            let data: GQL.SearchData = try await post(GQL.searchQuery, variables: vars)
            viewer = data.viewer.login
            requests += 1
            if let limit = data.rateLimit {
                rateLimit = limit
                cost += limit.cost
            }
            raw.append(contentsOf: data.search.nodes.compactMap { $0 })
            guard data.search.pageInfo.hasNextPage, let next = data.search.pageInfo.endCursor else { break }
            cursor = next
        }

        return SearchResult(
            viewerLogin: viewer,
            pullRequests: raw.compactMap(Self.materialize),
            rateLimit: rateLimit,
            cost: cost,
            requests: requests
        )
    }

    // MARK: - Internals

    /// Turns one pull request from GitHub's response into the app's model, or
    /// nil when a required field is missing (e.g. a search hit that is not a
    /// pull request).
    static func materialize(_ node: GQL.PullRequest) -> PullRequest? {
        guard let id = node.id, let number = node.number, let title = node.title,
              let url = node.url, let updatedAt = node.updatedAt,
              let repo = node.repository?.nameWithOwner
        else { return nil }

        var checks: Checks? = nil
        if let rollup = node.commits?.nodes.first?.commit.statusCheckRollup {
            checks = Checks(
                state: Checks.State(rawValue: rollup.state) ?? .pending,
                total: rollup.contexts.totalCount,
                passed: rollup.contexts.passedCount
            )
        }

        return PullRequest(
            id: id,
            number: number,
            title: title,
            url: url,
            isDraft: node.isDraft ?? false,
            updatedAt: updatedAt,
            author: node.author?.login ?? "ghost",
            repository: repo,
            reviewDecision: node.reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
            mergeable: node.mergeable.flatMap(Mergeable.init(rawValue:)) ?? .unknown,
            checks: checks,
            commentCount: node.comments?.totalCount ?? 0
        )
    }

    private func post<T: Decodable>(_ query: String, variables: [String: Any?]) async throws -> T {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("pullbar-menubar", forHTTPHeaderField: "User-Agent")
        let cleanVars = variables.compactMapValues { $0 }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": cleanVars])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.malformed }
        if http.statusCode == 401 { throw GitHubError.unauthorized }
        if let resetAt = Self.rateLimitReset(http) { throw GitHubError.rateLimited(resetAt: resetAt) }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        let envelope = try decoder.decode(GQL.Envelope<T>.self, from: data)
        if envelope.errors?.contains(where: { $0.type == "RATE_LIMITED" }) == true {
            throw GitHubError.rateLimited(resetAt: nil)
        }
        if let errors = envelope.errors, !errors.isEmpty, envelope.data == nil {
            throw GitHubError.graphQL(errors.map(\.message))
        }
        guard let payload = envelope.data else { throw GitHubError.malformed }
        return payload
    }

    /// When a response says the rate limit is used up (HTTP 403 or 429 with no
    /// requests remaining), the time it resets; nil for any other response.
    static func rateLimitReset(_ http: HTTPURLResponse) -> Date?? {
        guard [403, 429].contains(http.statusCode),
              http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || http.statusCode == 429
        else { return nil }
        let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
        return .some(reset.map { Date(timeIntervalSince1970: $0) })
    }
}

// MARK: - GraphQL wire format

enum GQL {
    struct Envelope<T: Decodable>: Decodable {
        struct Error: Decodable {
            let message: String
            var type: String? = nil
        }
        let data: T?
        let errors: [Error]?
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct Viewer: Decodable { let login: String }

    /// GitHub's GraphQL budget: points per hour, what is left, and this
    /// request's cost.
    struct RateLimit: Decodable, Equatable {
        let limit: Int
        let remaining: Int
        let used: Int
        let cost: Int
        let resetAt: Date
    }

    struct SearchData: Decodable {
        struct Search: Decodable {
            let issueCount: Int
            let pageInfo: PageInfo
            let nodes: [PullRequest?]
        }
        let viewer: Viewer
        let search: Search
        let rateLimit: RateLimit?
    }

    /// All fields optional: a search node that is not a PullRequest decodes
    /// to an empty object and is dropped.
    struct PullRequest: Decodable {
        struct Actor: Decodable { let login: String }
        struct Repository: Decodable { let nameWithOwner: String }
        struct Count: Decodable { let totalCount: Int }
        struct Commits: Decodable {
            struct Node: Decodable {
                struct Commit: Decodable { let statusCheckRollup: Rollup? }
                let commit: Commit
            }
            let nodes: [Node]
        }
        struct Rollup: Decodable {
            /// GitHub's counts of the head commit's checks, by state. Counting
            /// here instead of listing the checks keeps the total exact for any
            /// number of checks, in the same single request.
            struct Contexts: Decodable {
                struct StateCount: Decodable {
                    let state: String
                    let count: Int
                }
                let totalCount: Int
                let checkRunCountsByState: [StateCount]
                let statusContextCountsByState: [StateCount]

                /// Check runs that succeeded, were neutral, or were skipped, and
                /// commit statuses that succeeded.
                var passedCount: Int {
                    let passingRuns: Set = ["SUCCESS", "NEUTRAL", "SKIPPED"]
                    let runs = checkRunCountsByState.filter { passingRuns.contains($0.state) }
                    let statuses = statusContextCountsByState.filter { $0.state == "SUCCESS" }
                    return (runs + statuses).reduce(0) { $0 + $1.count }
                }
            }
            let state: String
            let contexts: Contexts
        }

        let id: String?
        let number: Int?
        let title: String?
        let url: URL?
        let isDraft: Bool?
        let updatedAt: Date?
        let mergeable: String?
        let reviewDecision: String?
        let author: Actor?
        let repository: Repository?
        let commits: Commits?
        let comments: Count?
    }

    static let pullRequestFields = """
    id
    number
    title
    url
    isDraft
    updatedAt
    mergeable
    reviewDecision
    author { login }
    repository { nameWithOwner }
    comments { totalCount }
    commits(last: 1) {
      nodes {
        commit {
          statusCheckRollup {
            state
            contexts(first: 0) {
              totalCount
              checkRunCountsByState { state count }
              statusContextCountsByState { state count }
            }
          }
        }
      }
    }
    """

    static let searchQuery = """
    query PullbarSearch($q: String!, $first: Int!, $after: String) {
      viewer { login }
      rateLimit { limit remaining used cost resetAt }
      search(query: $q, type: ISSUE, first: $first, after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            \(pullRequestFields)
          }
        }
      }
    }
    """
}
