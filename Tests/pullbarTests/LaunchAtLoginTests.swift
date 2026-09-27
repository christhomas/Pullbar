import AppKit
import ServiceManagement
import XCTest
@testable import pullbar

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
