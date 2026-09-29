import AppKit
import XCTest
@testable import pullbar

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
