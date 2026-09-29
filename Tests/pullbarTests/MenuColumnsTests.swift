import AppKit
import XCTest
@testable import pullbar

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
