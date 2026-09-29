import AppKit
import XCTest
@testable import pullbar

final class OwnerGroupingTests: XCTestCase {
    private func pr(_ repo: String, minutesAgo: Double, number: Int = 1) -> PullRequest {
        makePR(id: "\(repo)#\(number)", number: number, updatedAt: referenceDate.addingTimeInterval(-minutesAgo * 60), repository: repo)
    }

    func testOwnerIsTheRepositoryOwner() {
        XCTAssertEqual(makePR(repository: "acme/api").owner, "acme")
        XCTAssertEqual(makePR(repository: "octo-org/sub/path").owner, "octo-org")
        XCTAssertEqual(makePR(repository: "loner").owner, "loner")
    }

    func testGroupsAreOrderedByTheirNewestPullRequestAndThenByOwner() {
        let groups = Inbox.groupedByOwner([
            pr("globex/web", minutesAgo: 30),
            pr("acme/api", minutesAgo: 5),
            pr("globex/api", minutesAgo: 1, number: 2),
            pr("acme/infra", minutesAgo: 60),
            pr("zeta/x", minutesAgo: 90),
            pr("beta/y", minutesAgo: 90),
        ])
        // globex has the newest pull request, then acme; beta and zeta tie on
        // time and are ordered by name.
        XCTAssertEqual(groups.map(\.owner), ["globex", "acme", "beta", "zeta"])
        XCTAssertEqual(groups[0].pullRequests.map(\.repository), ["globex/api", "globex/web"], "newest first within a group")
        XCTAssertEqual(groups[1].pullRequests.map(\.repository), ["acme/api", "acme/infra"])
    }

    func testNoPullRequestsNoGroups() {
        XCTAssertTrue(Inbox.groupedByOwner([]).isEmpty)
    }

    func testEqualTimestampsUseRepositoryAndNumberAsTieBreakers() {
        let groups = Inbox.groupedByOwner([
            pr("acme/zebra", minutesAgo: 1, number: 2),
            pr("acme/alpha", minutesAgo: 1, number: 3),
            pr("acme/alpha", minutesAgo: 1, number: 1),
        ])
        XCTAssertEqual(groups[0].pullRequests.map(\.id), ["acme/alpha#1", "acme/alpha#3", "acme/zebra#2"])
    }

    @MainActor
    func testTheMenuHasASubheadingPerOwner() throws {
        let prs = [pr("globex/web", minutesAgo: 1), pr("acme/api", minutesAgo: 2), pr("globex/api", minutesAgo: 3, number: 2)]
        let app = AppDelegate()
        app.inboxForTesting = Inbox.build(reviewRequested: prs, userReviewRequested: prs, authored: [], viewerLogin: "")
        app.rebuildMenuForTesting()
        let items = app.menuForTesting.items
        let titles = items.map { $0.isSeparatorItem ? "---" : ($0.attributedTitle?.string ?? $0.title) }
        let start = titles.firstIndex(of: "NEEDS YOUR REVIEW  3")!
        XCTAssertEqual(titles[start + 1], "globex")
        XCTAssertTrue(titles[start + 2].contains("globex/web#1"))
        XCTAssertTrue(titles[start + 3].contains("globex/api#2"))
        XCTAssertEqual(titles[start + 4], "acme")
        XCTAssertTrue(titles[start + 5].contains("acme/api#1"))
        XCTAssertNil(items[start + 1].action, "subheadings are not clickable")
        let label = try XCTUnwrap(items[start + 1].view?.subviews.first as? NSTextField)
        XCTAssertEqual(label.stringValue, "globex")
        XCTAssertEqual(label.textColor, .labelColor, "black, not dimmed like a disabled item")
        XCTAssertTrue(label.font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertEqual(items[start + 2].indentationLevel, 2)
    }

    @MainActor
    func testTheOwnerIsBoldInEachRow() throws {
        let pr = makePR(number: 7, repository: "acme/api")
        let app = AppDelegate()
        app.inboxForTesting = Inbox.build(reviewRequested: [], userReviewRequested: [], authored: [pr], viewerLogin: "")
        app.rebuildMenuForTesting()
        let row = try XCTUnwrap(app.menuForTesting.items.first { $0.representedObject as? URL == pr.url })
        let title = try XCTUnwrap(row.attributedTitle)
        let details = (title.string as NSString).range(of: "acme/api#7 · ")
        XCTAssertNotEqual(details.location, NSNotFound, title.string)
        let ownerFont = try XCTUnwrap(title.attribute(.font, at: details.location, effectiveRange: nil) as? NSFont)
        let restFont = try XCTUnwrap(title.attribute(.font, at: details.location + 4, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(ownerFont.fontDescriptor.symbolicTraits.contains(.bold), "owner is bold")
        XCTAssertFalse(restFont.fontDescriptor.symbolicTraits.contains(.bold), "the rest is not")
        XCTAssertEqual(ownerFont.pointSize, restFont.pointSize)
    }
}
