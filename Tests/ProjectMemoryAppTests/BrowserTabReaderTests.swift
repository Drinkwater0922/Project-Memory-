import XCTest
@testable import ProjectMemoryApp
@testable import ProjectMemoryCore

final class BrowserTabReaderTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "BrowserTabReaderTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testUnsupportedBundleIDThrows() {
        let log = AutomationAttemptLog(defaults: defaults)
        let reader = OSABrowserTabReader(attemptLog: log)
        XCTAssertThrowsError(try reader.readActiveTab(bundleID: "com.unknown.app"))
    }
}
