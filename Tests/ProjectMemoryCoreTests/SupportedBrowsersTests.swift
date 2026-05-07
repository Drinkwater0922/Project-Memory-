import XCTest
@testable import ProjectMemoryCore

final class SupportedBrowsersTests: XCTestCase {
    func testBundleIDsContainsExpectedBrowsers() {
        XCTAssertTrue(SupportedBrowsers.bundleIDs.contains("com.apple.Safari"))
        XCTAssertTrue(SupportedBrowsers.bundleIDs.contains("com.google.Chrome"))
        XCTAssertTrue(SupportedBrowsers.bundleIDs.contains("com.brave.Browser"))
        XCTAssertTrue(SupportedBrowsers.bundleIDs.contains("com.microsoft.edgemac"))
        XCTAssertTrue(SupportedBrowsers.bundleIDs.contains("company.thebrowser.Browser"))
    }

    func testDialectForSafariReturnsSafari() {
        XCTAssertEqual(SupportedBrowsers.dialect(for: "com.apple.Safari"), .safari)
    }

    func testDialectForChromeFamilyReturnsChromium() {
        XCTAssertEqual(SupportedBrowsers.dialect(for: "com.google.Chrome"), .chromium)
        XCTAssertEqual(SupportedBrowsers.dialect(for: "com.brave.Browser"), .chromium)
        XCTAssertEqual(SupportedBrowsers.dialect(for: "com.microsoft.edgemac"), .chromium)
        XCTAssertEqual(SupportedBrowsers.dialect(for: "company.thebrowser.Browser"), .chromium)
    }

    func testDialectForUnknownReturnsNil() {
        XCTAssertNil(SupportedBrowsers.dialect(for: "com.unknown.app"))
    }
}
