import XCTest
@testable import ProjectMemoryCore

final class ActivityGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func candidate(
        bundleID: String = "com.tinyspeck.slackmacgap",
        browserURL: String? = nil
    ) -> ActivityCandidate {
        ActivityCandidate(
            observedAt: now,
            bundleID: bundleID,
            appName: "App",
            windowTitle: nil,
            browserURL: browserURL
        )
    }

    func testCaptureWhenAllChecksPass() {
        let decision = ActivityGate.decide(
            candidate: candidate(),
            now: now,
            lastCaptureAt: nil,
            extraDenied: []
        )
        XCTAssertEqual(decision, .capture)
    }

    func testSkipWhenBundleIDInDefaultDeny() {
        let decision = ActivityGate.decide(
            candidate: candidate(bundleID: "com.1password.1password"),
            now: now,
            lastCaptureAt: nil,
            extraDenied: []
        )
        XCTAssertEqual(decision, .skip(reason: "app_denied"))
    }

    func testSkipWhenBundleIDInExtraDenied() {
        let decision = ActivityGate.decide(
            candidate: candidate(bundleID: "com.example.private"),
            now: now,
            lastCaptureAt: nil,
            extraDenied: ["com.example.private"]
        )
        XCTAssertEqual(decision, .skip(reason: "app_denied"))
    }

    func testSkipWhenBrowserURLDenied() {
        let decision = ActivityGate.decide(
            candidate: candidate(browserURL: "https://accounts.google.com/login"),
            now: now,
            lastCaptureAt: nil,
            extraDenied: []
        )
        XCTAssertEqual(decision, .skip(reason: "url_denied"))
    }

    func testSkipWhenWithinRateLimitWindow() {
        let decision = ActivityGate.decide(
            candidate: candidate(),
            now: now,
            lastCaptureAt: now.addingTimeInterval(-3),
            extraDenied: []
        )
        XCTAssertEqual(decision, .skip(reason: "rate_limited"))
    }

    func testCaptureWhenLastCaptureBeforeRateLimit() {
        let decision = ActivityGate.decide(
            candidate: candidate(),
            now: now,
            lastCaptureAt: now.addingTimeInterval(-6),
            extraDenied: []
        )
        XCTAssertEqual(decision, .capture)
    }

    func testCaptureWhenBrowserURLIsNil() {
        let decision = ActivityGate.decide(
            candidate: candidate(bundleID: "com.apple.Safari", browserURL: nil),
            now: now,
            lastCaptureAt: nil,
            extraDenied: []
        )
        XCTAssertEqual(decision, .capture)
    }
}
