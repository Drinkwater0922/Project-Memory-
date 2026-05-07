import XCTest
@testable import ProjectMemoryApp

final class AutomationAttemptLogTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "AutomationAttemptLogTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testInitialOutcomeIsNotAttempted() {
        let log = AutomationAttemptLog(defaults: defaults)
        XCTAssertEqual(log.outcome(forBundleID: "com.apple.Safari"), .notAttempted)
    }

    func testRecordSuccessThenFailureOverwrites() {
        let log = AutomationAttemptLog(defaults: defaults)
        log.recordSuccess(bundleID: "com.apple.Safari", at: Date(timeIntervalSince1970: 1))
        log.recordFailure(bundleID: "com.apple.Safari", at: Date(timeIntervalSince1970: 2), reason: "denied")

        if case .failure(let at, let reason) = log.outcome(forBundleID: "com.apple.Safari") {
            XCTAssertEqual(at.timeIntervalSince1970, 2)
            XCTAssertEqual(reason, "denied")
        } else {
            XCTFail("Expected .failure outcome")
        }
    }

    func testMultipleBrowsersIsolated() {
        let log = AutomationAttemptLog(defaults: defaults)
        log.recordSuccess(bundleID: "com.apple.Safari", at: Date(timeIntervalSince1970: 1))
        log.recordFailure(bundleID: "com.google.Chrome", at: Date(timeIntervalSince1970: 2), reason: "x")

        if case .success(let at) = log.outcome(forBundleID: "com.apple.Safari") {
            XCTAssertEqual(at.timeIntervalSince1970, 1)
        } else { XCTFail() }
        if case .failure(let at, _) = log.outcome(forBundleID: "com.google.Chrome") {
            XCTAssertEqual(at.timeIntervalSince1970, 2)
        } else { XCTFail() }
    }

    func testPersistsAcrossInstances() {
        do {
            let log = AutomationAttemptLog(defaults: defaults)
            log.recordSuccess(bundleID: "com.apple.Safari", at: Date(timeIntervalSince1970: 5))
        }
        let log2 = AutomationAttemptLog(defaults: defaults)
        if case .success(let at) = log2.outcome(forBundleID: "com.apple.Safari") {
            XCTAssertEqual(at.timeIntervalSince1970, 5)
        } else { XCTFail() }
    }
}
