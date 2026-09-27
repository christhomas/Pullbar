import AppKit
import ServiceManagement
import XCTest
@testable import pullbar

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// MARK: - Status columns in pull request rows

final class MenuColumnsTests: XCTestCase {
    private func text(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.menuFont(ofSize: 11)])
    }

    private func tabStops(_ line: NSAttributedString) -> [NSTextTab] {
        (line.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.tabStops ?? []
    }

    func testEveryRowUsesTheSameTabStops() {
        let rows = [
            [text("short"), text("Approved"), text("✓ 3/3"), text(""), text("💬 1")],
            [text("a much longer details column"), text("Review not required"), text("✓ 120/120"), text("⚠︎ conflicts"), text("💬 289")],
        ]
        let columns = MenuColumns(rows: rows, titles: [])
        let lines = rows.map(columns.line)
        let stops = lines.map { tabStops($0).map(\.location) }
        XCTAssertEqual(stops[0], stops[1])
        XCTAssertEqual(stops[0].count, 4, "one stop per status column")
        XCTAssertEqual(stops[0], stops[0].sorted(), "columns run left to right")
        XCTAssertTrue(tabStops(lines[0]).allSatisfy { $0.alignment == .left })
    }

    func testStatusColumnsStartAfterTheWidestDetails() throws {
        let widest = text("a much longer details column")
        let rows = [[text("short"), text("Approved")], [widest, text("Approved")]]
        let first = try XCTUnwrap(tabStops(MenuColumns(rows: rows, titles: []).line(rows[0])).first)
        XCTAssertEqual(first.location, ceil(widest.size().width) + MenuColumns.gap, accuracy: 0.5)
    }

    func testColumnsEmptyInEveryRowAreLeftOut() {
        let rows = [
            [text("a"), text("Approved"), text(""), text("💬 1")],
            [text("b"), text("Approved"), text(""), text("💬 2")],
        ]
        let columns = MenuColumns(rows: rows, titles: [])
        let line = columns.line(rows[0])
        XCTAssertEqual(tabStops(line).count, 2)
        XCTAssertEqual(line.string, "a\tApproved\t💬 1")
    }

    func testAWideTitlePushesTheStatusBlockRight() throws {
        let rows = [[text("a"), text("Approved")]]
        let narrow = try XCTUnwrap(tabStops(MenuColumns(rows: rows, titles: []).line(rows[0])).first).location
        let wideTitle = NSAttributedString(string: String(repeating: "W", count: 80),
                                           attributes: [.font: NSFont.menuFont(ofSize: 13)])
        let pushed = try XCTUnwrap(tabStops(MenuColumns(rows: rows, titles: [wideTitle]).line(rows[0])).first).location
        XCTAssertGreaterThan(pushed, narrow)
        // The status block ends at the right edge of the title.
        let statusWidth = MenuColumns.gap + ceil(text("Approved").size().width)
        XCTAssertEqual(pushed + statusWidth - MenuColumns.gap, ceil(wideTitle.size().width), accuracy: 0.5)
    }

    @MainActor
    func testRowColumnsForAPullRequest() {
        let app = AppDelegate()
        let pr = makePR(number: 7, author: "mona", repository: "acme/api", reviewDecision: .approved,
                        mergeable: .conflicting, checks: checks(.failure, passed: 2, total: 5), commentCount: 9)
        let columns = app.statusColumnsForTesting(pr).map(\.string)
        XCTAssertEqual(columns.count, 5)
        XCTAssertTrue(columns[0].hasPrefix("acme/api#7 · mona · updated "), columns[0])
        XCTAssertEqual(columns[1], "● Approved")
        XCTAssertEqual(columns[2], "✕ 2/5")
        XCTAssertEqual(columns[3], "⚠︎ conflicts")
        XCTAssertEqual(columns[4], "💬 9")

        let quiet = app.statusColumnsForTesting(makePR(checks: nil)).map(\.string)
        XCTAssertEqual(quiet[2], "", "no checks column text")
        XCTAssertEqual(quiet[3], "", "no conflict column text")
        XCTAssertEqual(app.statusColumnsForTesting(makePR(checks: checks(.pending))).map(\.string)[2], "● 1/1")
        XCTAssertEqual(app.statusColumnsForTesting(makePR(checks: checks(.success))).map(\.string)[2], "✓ 1/1")
    }
}

// MARK: - Fixtures

final class FixtureTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRelativeTimes() {
        XCTAssertEqual(Fixture.PR.seconds("45m"), 2700)
        XCTAssertEqual(Fixture.PR.seconds("3h"), 10_800)
        XCTAssertEqual(Fixture.PR.seconds("2d"), 172_800)
        XCTAssertEqual(Fixture.PR.seconds("5w"), 3_024_000)
        XCTAssertEqual(Fixture.PR.seconds("1.5h"), 5400)
        for bad in ["3y", "", "h", "tenm", "3 h"] {
            XCTAssertNil(Fixture.PR.seconds(bad), bad)
        }
    }

    func testFixtureArgument() {
        XCTAssertEqual(Fixture.path(in: ["pullbar", "--fixture", "/tmp/x.json"]), "/tmp/x.json")
        XCTAssertNil(Fixture.path(in: ["pullbar"]))
        XCTAssertNil(Fixture.path(in: ["pullbar", "--fixture"]), "flag without a value")
    }

    func testFixtureBecomesAnInbox() throws {
        let url = try write("""
        {
          "viewerLogin": "octocat",
          "direct": [{ "number": 1, "title": "Direct", "repository": "acme/a", "author": "mona", "updated": "1h" }],
          "teams": [{ "number": 2, "title": "Team", "repository": "acme/b", "author": "hubot", "updated": "2h" }],
          "authored": [
            { "number": 3, "title": "Draft", "repository": "acme/c", "author": "octocat", "updated": "3h", "isDraft": true },
            { "number": 4, "title": "Ready", "repository": "acme/c", "author": "octocat", "updated": "4h",
              "reviewDecision": "APPROVED", "checks": { "state": "SUCCESS", "passed": 5, "total": 5 }, "comments": 12 },
            { "number": 5, "title": "Conflict", "repository": "acme/c", "author": "octocat", "updated": "1d",
              "reviewDecision": "APPROVED", "mergeable": "CONFLICTING" }
          ]
        }
        """)
        let inbox = try Fixture.load(from: url).inbox(now: referenceDate)
        XCTAssertEqual(inbox.viewerLogin, "octocat")
        XCTAssertEqual(inbox.pullRequests(in: .needsYourReview).map(\.title), ["Direct"])
        XCTAssertEqual(inbox.pullRequests(in: .needsTeamsReview).map(\.title), ["Team"])
        XCTAssertEqual(inbox.pullRequests(in: .yourDrafts).map(\.title), ["Draft"])
        XCTAssertEqual(inbox.pullRequests(in: .readyToMerge).map(\.title), ["Ready"])
        XCTAssertEqual(inbox.pullRequests(in: .needsAction).map(\.title), ["Conflict"])

        let direct = try XCTUnwrap(inbox.pullRequests(in: .needsYourReview).first)
        XCTAssertEqual(direct.id, "acme/a#1")
        XCTAssertEqual(direct.url.absoluteString, "https://github.com/acme/a/pull/1")
        XCTAssertEqual(direct.updatedAt, referenceDate.addingTimeInterval(-3600))
        XCTAssertFalse(direct.isDraft)
        XCTAssertEqual(direct.mergeable, .mergeable)
        XCTAssertNil(direct.checks)
        XCTAssertEqual(direct.commentCount, 0)

        let ready = try XCTUnwrap(inbox.pullRequests(in: .readyToMerge).first)
        XCTAssertEqual(ready.checks, Checks(state: .success, total: 5, passed: 5))
        XCTAssertEqual(ready.commentCount, 12)
    }

    func testInvalidValuesNameThePullRequestAndField() throws {
        let cases = [
            (#""updated": "3y""#, "updated must look like"),
            (#""updated": "1h", "reviewDecision": "MAYBE""#, "unknown reviewDecision MAYBE"),
            (#""updated": "1h", "mergeable": "SOMETIMES""#, "unknown mergeable SOMETIMES"),
            (#""updated": "1h", "checks": { "state": "GREEN", "passed": 1, "total": 1 }"#, "unknown checks state GREEN"),
        ]
        for (fields, message) in cases {
            let url = try write(#"{ "viewerLogin": "x", "authored": [{ "number": 1, "title": "t", "repository": "acme/app", "author": "a", "# + fields + " }] }")
            XCTAssertThrowsError(try Fixture.load(from: url).inbox(now: referenceDate)) { error in
                let text = error.localizedDescription
                XCTAssertTrue(text.hasPrefix("Fixture acme/app#1: "), text)
                XCTAssertTrue(text.contains(message), "\(text) should mention \(message)")
            }
        }
    }

    func testEmptyFixtureHasEmptySections() throws {
        let inbox = try Fixture.load(from: write(#"{ "viewerLogin": "x" }"#)).inbox(now: referenceDate)
        for section in InboxSection.allCases {
            XCTAssertEqual(inbox.count(section), 0)
        }
    }

    func testTheBundledFixturesLoad() throws {
        let fixtures = repositoryRoot.appendingPathComponent("Fixtures")
        let showcase = try Fixture.load(from: fixtures.appendingPathComponent("showcase.json")).inbox(now: referenceDate)
        XCTAssertEqual(InboxSection.allCases.map(showcase.count), [2, 2, 1, 2, 3, 3])

        XCTAssertEqual(try Fixture.load(from: fixtures.appendingPathComponent("empty.json")).inbox().count(.needsYourReview), 0)

        let error = try Fixture.load(from: fixtures.appendingPathComponent("error.json"))
        XCTAssertEqual(error.error, "GitHub rejected the token (401). Set a new one.")
        XCTAssertEqual(try error.inbox().count(.needsYourReview), 1)
    }

    @MainActor
    func testTheAppShowsAFixtureAndItsError() throws {
        let app = AppDelegate()
        app.installStatusItemForTesting()
        defer { app.removeStatusItemForTesting() }
        app.loadFixtureForTesting(repositoryRoot.appendingPathComponent("Fixtures/error.json"))
        XCTAssertEqual(app.inboxForTesting?.count(.needsYourReview), 1)
        XCTAssertEqual(app.lastErrorForTesting?.localizedDescription, "GitHub rejected the token (401). Set a new one.")

        app.loadFixtureForTesting(repositoryRoot.appendingPathComponent("Fixtures/showcase.json"))
        XCTAssertNil(app.lastErrorForTesting)
        XCTAssertEqual(app.inboxForTesting?.count(.readyToMerge), 3)
    }

    @MainActor
    func testTheAppReportsABrokenFixture() throws {
        let app = AppDelegate()
        app.installStatusItemForTesting()
        defer { app.removeStatusItemForTesting() }
        app.loadFixtureForTesting(try write("not json"))
        XCTAssertNil(app.inboxForTesting)
        XCTAssertNotNil(app.lastErrorForTesting)
    }
}

// MARK: - Launch at login

final class LaunchAtLoginModeTests: XCTestCase {
    private func mode(_ path: String, _ status: SMAppService.Status) -> LaunchAtLoginMode {
        LaunchAtLoginMode.mode(bundlePath: path, status: status)
    }

    func testNormalInstall() {
        XCTAssertEqual(mode("/Applications/pullbar.app", .enabled), .available(enabled: true))
        XCTAssertEqual(mode("/Applications/pullbar.app", .notRegistered), .available(enabled: false))
        XCTAssertEqual(mode("/Applications/pullbar.app", .notFound), .available(enabled: false))
        XCTAssertEqual(mode("/Users/me/Applications/pullbar.app", .enabled), .available(enabled: true))
        // An app on an external drive is a normal install too.
        XCTAssertEqual(mode("/Volumes/Data/pullbar/build/pullbar.app", .notRegistered), .available(enabled: false))
    }

    func testSwitchedOffInSystemSettings() {
        XCTAssertEqual(mode("/Applications/pullbar.app", .requiresApproval), .needsApproval)
    }

    func testQuarantinedDownloadMustBeMovedFirst() {
        XCTAssertEqual(mode("/private/var/folders/ab/T/AppTranslocation/1234/d/pullbar.app", .notRegistered), .moveToApplications)
        XCTAssertEqual(mode("/private/var/folders/ab/T/AppTranslocation/1234/d/pullbar.app", .enabled), .moveToApplications)
    }

    func testHomebrewFormulaUsesBrewServices() {
        XCTAssertEqual(mode("/opt/homebrew/Cellar/pullbar/1.2.3/pullbar.app", .enabled), .managedByHomebrew)
    }

    func testBareBinaryIsUnavailable() {
        XCTAssertEqual(mode("/Users/me/pullbar/.build/release", .notRegistered), .unavailable)
        XCTAssertEqual(mode("/usr/local/bin/pullbar", .enabled), .unavailable)
    }
}

// MARK: - Title row

@MainActor
final class TitleRowTests: XCTestCase {
    func testVersionTitle() {
        XCTAssertEqual(AppDelegate.versionTitle(info: ["CFBundleShortVersionString": "1.2.3"]), "PullBar version 1.2.3")
        XCTAssertEqual(AppDelegate.versionTitle(info: ["CFBundleShortVersionString": ""]), "PullBar development build")
        XCTAssertEqual(AppDelegate.versionTitle(info: [:]), "PullBar development build")
        XCTAssertEqual(AppDelegate.versionTitle(info: nil), "PullBar development build")
    }

    func testBuildOrigin() {
        let origin = AppDelegate.buildOrigin(info: [
            "PullbarBuildDescription": "v1.2.3-4-gabcdef0",
            "PullbarSourceRepository": "https://github.com/lucaspal/Pullbar",
        ])
        XCTAssertEqual(origin.description, "v1.2.3-4-gabcdef0")
        XCTAssertEqual(origin.repository?.absoluteString, "https://github.com/lucaspal/Pullbar")

        let empty = AppDelegate.buildOrigin(info: ["PullbarBuildDescription": ""])
        XCTAssertNil(empty.description)
        XCTAssertNil(empty.repository)
    }

    func testTwoLineClickableTitle() {
        let item = AppDelegate().titleItemForTesting(info: [
            "CFBundleShortVersionString": "1.2.3",
            "PullbarBuildDescription": "v1.2.3",
            "PullbarSourceRepository": "https://github.com/lucaspal/Pullbar",
        ])
        XCTAssertEqual(item.attributedTitle?.string, "PullBar version 1.2.3\nv1.2.3 · github.com/lucaspal/Pullbar")
        XCTAssertTrue(item.isEnabled)
        XCTAssertNotNil(item.action)
        XCTAssertEqual(item.representedObject as? URL, URL(string: "https://github.com/lucaspal/Pullbar"))
        XCTAssertEqual(item.toolTip, "Open https://github.com/lucaspal/Pullbar")
    }

    func testTitleWithoutBuildInfoIsOneDisabledLine() {
        let item = AppDelegate().titleItemForTesting(info: ["CFBundleShortVersionString": "1.2.3"])
        XCTAssertEqual(item.attributedTitle?.string, "PullBar version 1.2.3")
        XCTAssertFalse(item.isEnabled)
    }

    func testTheMenuStartsWithTheTitleRow() {
        let app = AppDelegate()
        app.rebuildMenuForTesting()
        let items = app.menuForTesting.items
        XCTAssertTrue(items[0].attributedTitle?.string.hasPrefix("PullBar ") ?? false)
        XCTAssertTrue(items[1].isSeparatorItem)
    }
}

// MARK: - Live menu sync

@MainActor
final class LiveSyncTests: XCTestCase {
    private func inbox(directTitles: [String]) -> Inbox {
        let prs = directTitles.map { makePR(title: $0) }
        return Inbox.build(reviewRequested: prs, userReviewRequested: prs, authored: [], viewerLogin: "octocat")
    }

    private func menuText(_ app: AppDelegate) -> [String] {
        app.menuForTesting.items.map { $0.attributedTitle?.string ?? $0.title }
    }

    func testTheOpenMenuUpdatesAndTheTitleWaitsForClose() {
        let app = AppDelegate()
        app.installStatusItemForTesting()
        defer { app.removeStatusItemForTesting() }

        app.inboxForTesting = inbox(directTitles: ["First"])
        app.renderForTesting()
        XCTAssertEqual(app.statusTitleForTesting, "1")

        app.menuWillOpen(app.menuForTesting)
        XCTAssertTrue(app.menuIsOpenForTesting)
        app.rebuildMenuForTesting()

        // New data arrives while the menu is open.
        app.inboxForTesting = inbox(directTitles: ["First", "Second"])
        app.renderForTesting()
        XCTAssertTrue(menuText(app).contains { $0.hasPrefix("Second\n") }, "the open menu shows the new pull request")
        XCTAssertEqual(app.statusTitleForTesting, "1", "the menu bar title waits while the menu is open")
        XCTAssertTrue(app.statusTitleIsStaleForTesting)

        app.menuDidClose(app.menuForTesting)
        XCTAssertFalse(app.menuIsOpenForTesting)
        XCTAssertFalse(app.statusTitleIsStaleForTesting)
        XCTAssertEqual(app.statusTitleForTesting, "2", "the title is applied when the menu closes")
    }

    func testClosingWithoutChangesLeavesTheTitleAlone() {
        let app = AppDelegate()
        app.installStatusItemForTesting()
        defer { app.removeStatusItemForTesting() }

        app.inboxForTesting = inbox(directTitles: ["Only"])
        app.renderForTesting()
        app.menuWillOpen(app.menuForTesting)
        app.menuDidClose(app.menuForTesting)
        XCTAssertFalse(app.statusTitleIsStaleForTesting)
        XCTAssertEqual(app.statusTitleForTesting, "1")
    }
}

@MainActor
final class RefreshTimerTests: XCTestCase {
    private var savedInterval: TimeInterval = 120

    override func setUp() {
        super.setUp()
        savedInterval = Settings.shared.refreshInterval
    }

    override func tearDown() {
        Settings.shared.refreshInterval = savedInterval
        super.tearDown()
    }

    /// An open menu runs the event-tracking run-loop mode. A timer in the
    /// default mode only would not fire there, so refreshes would pause
    /// while you look at the menu.
    func testTheRefreshTimerFiresWhileTheMenuIsOpen() throws {
        // AppKit adds event tracking to the common modes, as in the real app.
        _ = NSApplication.shared
        let app = AppDelegate()
        Settings.shared.refreshInterval = 0.05
        app.scheduleTimerForTesting()
        let timer = try XCTUnwrap(app.timerForTesting)
        defer { timer.invalidate() }
        timer.tolerance = 0
        let firstFire = timer.fireDate

        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(mode: .eventTracking, before: deadline)
        }
        XCTAssertGreaterThan(timer.fireDate, firstFire, "the timer fired during event tracking")
    }
}
