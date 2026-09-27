import XCTest
@testable import pullbar

final class UpdatedWindowTests: XCTestCase {
    func testTitlesAndDays() {
        XCTAssertEqual(UpdatedWindow.allCases.map(\.title), ["Last week", "Last month", "Last 3 months", "Any time"])
        XCTAssertEqual(UpdatedWindow.allCases.map(\.days), [7, 31, 92, nil])
    }

    func testSearchQualifierCountsBackInUTC() {
        let now = ISO8601DateFormatter().date(from: "2026-03-10T00:30:00Z")!
        XCTAssertEqual(UpdatedWindow.week.searchQualifier(now: now), "updated:>=2026-03-03")
        XCTAssertEqual(UpdatedWindow.month.searchQualifier(now: now), "updated:>=2026-02-07")
        XCTAssertEqual(UpdatedWindow.quarter.searchQualifier(now: now), "updated:>=2025-12-08")
        XCTAssertNil(UpdatedWindow.all.searchQualifier(now: now))
    }

    func testSearchQualifierJustBeforeMidnightUTC() {
        let now = ISO8601DateFormatter().date(from: "2026-03-10T23:59:59Z")!
        XCTAssertEqual(UpdatedWindow.week.searchQualifier(now: now), "updated:>=2026-03-03")
    }

    func testSearchQualifierUsesTheCurrentDate() throws {
        let qualifier = try XCTUnwrap(UpdatedWindow.week.searchQualifier)
        XCTAssertEqual(qualifier, UpdatedWindow.week.searchQualifier(now: Date()))
        XCTAssertNil(UpdatedWindow.all.searchQualifier)
    }
}

@MainActor
final class SettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "pullbar-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaults() {
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.updatedWindow, .month)
        XCTAssertEqual(settings.refreshInterval, 120)
    }

    func testRoundTrip() {
        let settings = Settings(defaults: defaults)
        settings.updatedWindow = .quarter
        settings.refreshInterval = 300
        let reread = Settings(defaults: defaults)
        XCTAssertEqual(reread.updatedWindow, .quarter)
        XCTAssertEqual(reread.refreshInterval, 300)
    }

    func testInvalidStoredValuesFallBack() {
        defaults.set("fortnight", forKey: "updatedWindow")
        defaults.set(0.0, forKey: "refreshInterval")
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.updatedWindow, .month)
        XCTAssertEqual(settings.refreshInterval, 120)

        defaults.set(-5.0, forKey: "refreshInterval")
        XCTAssertEqual(Settings(defaults: defaults).refreshInterval, 120)
    }

    func testRefreshChoices() {
        XCTAssertEqual(Settings.refreshChoices, [60, 120, 300, 900])
    }
}
