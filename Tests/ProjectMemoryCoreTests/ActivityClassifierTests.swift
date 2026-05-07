import XCTest
@testable import ProjectMemoryCore

final class ActivityClassifierTests: XCTestCase {
    private func candidate(
        bundleID: String,
        browserURL: String? = nil
    ) -> ActivityCandidate {
        ActivityCandidate(
            observedAt: Date(),
            bundleID: bundleID,
            appName: "App",
            windowTitle: nil,
            browserURL: browserURL
        )
    }

    func testSlackBundleIDIsChat() {
        XCTAssertEqual(
            ActivityClassifier.classify(candidate(bundleID: "com.tinyspeck.slackmacgap")),
            .chat
        )
    }

    func testIMessageBundleIDIsChat() {
        XCTAssertEqual(
            ActivityClassifier.classify(candidate(bundleID: "com.apple.MobileSMS")),
            .chat
        )
    }

    func testVSCodeBundleIDIsWork() {
        XCTAssertEqual(
            ActivityClassifier.classify(candidate(bundleID: "com.microsoft.VSCode")),
            .work
        )
    }

    func testXcodeBundleIDIsWork() {
        XCTAssertEqual(
            ActivityClassifier.classify(candidate(bundleID: "com.apple.dt.Xcode")),
            .work
        )
    }

    func testChromeWithTwitterURLIsSocialMedia() {
        XCTAssertEqual(
            ActivityClassifier.classify(
                candidate(bundleID: "com.google.Chrome", browserURL: "https://twitter.com/user")
            ),
            .socialMedia
        )
    }

    func testChromeWithSwiftOrgURLIsWork() {
        XCTAssertEqual(
            ActivityClassifier.classify(
                candidate(bundleID: "com.google.Chrome", browserURL: "https://swift.org/docs")
            ),
            .work
        )
    }

    func testChromeWithSlackURLIsChat() {
        XCTAssertEqual(
            ActivityClassifier.classify(
                candidate(bundleID: "com.google.Chrome", browserURL: "https://acme.slack.com/messages")
            ),
            .chat
        )
    }

    func testBrowserWithUnknownHostIsOther() {
        XCTAssertEqual(
            ActivityClassifier.classify(
                candidate(bundleID: "com.google.Chrome", browserURL: "https://example.com/page")
            ),
            .other
        )
    }

    func testBrowserWithNilURLIsOther() {
        XCTAssertEqual(
            ActivityClassifier.classify(
                candidate(bundleID: "com.apple.Safari", browserURL: nil)
            ),
            .other
        )
    }

    func testUnknownBundleIDIsOther() {
        XCTAssertEqual(
            ActivityClassifier.classify(candidate(bundleID: "com.unknown.app")),
            .other
        )
    }
}
