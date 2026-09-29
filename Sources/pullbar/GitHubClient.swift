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

/// Minimal GitHub GraphQL client: one `search` per inbox query, plus paging
/// of check contexts for PRs with more than 100 checks.
final class GitHubClient: @unchecked Sendable {
    private let token: String
    private let endpoint = URL(string: "https://api.github.com/graphql")!
    private let session: URLSession
    private let decoder: JSONDecoder

    init(token: String) {
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Public

    struct SearchResult {
        let viewerLogin: String
        let pullRequests: [PullRequest]
        /// GitHub's budget after the last request, and what all requests
        /// cost: the search pages plus any extra pages of check contexts.
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
        var usage = Usage()
        for _ in 0..<maxPages {
            let vars: [String: Any?] = ["q": "is:pr \(query)", "first": 100, "after": cursor]
            let data: GQL.SearchData = try await post(GQL.searchQuery, variables: vars)
            viewer = data.viewer.login
            usage.count(data.rateLimit)
            raw.append(contentsOf: data.search.nodes.compactMap { $0 })
            guard data.search.pageInfo.hasNextPage, let next = data.search.pageInfo.endCursor else { break }
            cursor = next
        }

        // Finish counting checks where the first page of 100 contexts was not all of them.
        var prs: [PullRequest] = []
        try await withThrowingTaskGroup(of: (PullRequest?, Usage).self) { group in
            for node in raw {
                group.addTask { try await self.materialize(node) }
            }
            for try await (pr, extra) in group {
                if let pr { prs.append(pr) }
                usage.add(extra)
            }
        }
        return SearchResult(
            viewerLogin: viewer, pullRequests: prs,
            rateLimit: usage.rateLimit, cost: usage.cost, requests: usage.requests
        )
    }

    // MARK: - Internals

    /// Requests made, the points they cost, and the latest budget GitHub
    /// reported. Requests run in parallel, so the latest budget is the one
    /// with the least remaining.
    private struct Usage {
        var rateLimit: GQL.RateLimit?
        var cost = 0
        var requests = 0

        /// Counts one request and the budget in its response.
        mutating func count(_ limit: GQL.RateLimit?) {
            add(Usage(rateLimit: limit, cost: limit?.cost ?? 0, requests: 1))
        }

        mutating func add(_ other: Usage) {
            requests += other.requests
            cost += other.cost
            if let limit = other.rateLimit, rateLimit.map({ limit.remaining <= $0.remaining }) ?? true {
                rateLimit = limit
            }
        }
    }

    /// The pull request, plus what fetching its extra check contexts cost.
    private func materialize(_ node: GQL.PullRequest) async throws -> (PullRequest?, Usage) {
        var usage = Usage()
        guard let id = node.id, let number = node.number, let title = node.title,
              let url = node.url, let updatedAt = node.updatedAt,
              let repo = node.repository?.nameWithOwner
        else { return (nil, usage) }

        var checks: Checks? = nil
        if let rollup = node.commits?.nodes.first?.commit.statusCheckRollup {
            var contexts = rollup.contexts.nodes
            var page = rollup.contexts.pageInfo
            while page.hasNextPage, let after = page.endCursor {
                let more: GQL.NodeData = try await post(
                    GQL.contextsQuery, variables: ["id": id, "after": after]
                )
                usage.count(more.rateLimit)
                guard let next = more.node?.commits?.nodes.first?.commit.statusCheckRollup?.contexts else { break }
                contexts.append(contentsOf: next.nodes)
                page = next.pageInfo
            }
            let passed = contexts.filter(\.passed).count
            checks = Checks(
                state: Checks.State(rawValue: rollup.state) ?? .pending,
                total: rollup.contexts.totalCount,
                passed: passed
            )
        }

        let pr = PullRequest(
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
        return (pr, usage)
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

    struct NodeData: Decodable {
        let node: PullRequest?
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
            struct Contexts: Decodable {
                let totalCount: Int
                let pageInfo: PageInfo
                let nodes: [Context]
            }
            struct Context: Decodable {
                let __typename: String
                let status: String?
                let conclusion: String?
                let state: String?

                var passed: Bool {
                    switch __typename {
                    case "CheckRun":
                        return ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(conclusion ?? "")
                    case "StatusContext":
                        return state == "SUCCESS"
                    default:
                        return false
                    }
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
            contexts(first: 100) {
              totalCount
              pageInfo { hasNextPage endCursor }
              nodes {
                __typename
                ... on CheckRun { status conclusion }
                ... on StatusContext { state }
              }
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

    static let contextsQuery = """
    query PullbarContexts($id: ID!, $after: String!) {
      rateLimit { limit remaining used cost resetAt }
      node(id: $id) {
        ... on PullRequest {
          commits(last: 1) {
            nodes {
              commit {
                statusCheckRollup {
                  state
                  contexts(first: 100, after: $after) {
                    totalCount
                    pageInfo { hasNextPage endCursor }
                    nodes {
                      __typename
                      ... on CheckRun { status conclusion }
                      ... on StatusContext { state }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """
}
