// Tests/ProjectMemoryCoreTests/SessionAggregatorTests.swift
import XCTest
@testable import ProjectMemoryCore

final class SessionAggregatorTests: XCTestCase {
    private let chrome = "com.google.Chrome"
    private let cursor = "com.todesktop.230313mzl4w4u92"
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func frame(_ offset: TimeInterval, bundleID: String, host: String? = nil, title: String? = nil, category: ActivityCategory = .work) -> ActivityFrame {
        ActivityFrame(
            observedAt: t0.addingTimeInterval(offset),
            bundleID: bundleID,
            appName: bundleID,
            windowTitle: title,
            browserURL: host.map { "https://\($0)/some/path?q=1" },
            category: category
        )
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertEqual(SessionAggregator.aggregate([]), [])
    }

    func testSingleFrameDropped() {
        let f = frame(0, bundleID: cursor, title: "x")
        XCTAssertEqual(SessionAggregator.aggregate([f]), [])
    }

    func testSameIdentityWithinGapIsOneSession() {
        let f1 = frame(0, bundleID: cursor, title: "a")
        let f2 = frame(60, bundleID: cursor, title: "a")
        let f3 = frame(120, bundleID: cursor, title: "b")
        let drafts = SessionAggregator.aggregate([f1, f2, f3])
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].frameCount, 3)
        XCTAssertEqual(drafts[0].id, f1.id)  // = firstFrame.id
        XCTAssertEqual(drafts[0].titleSamples, ["a", "b"])
    }

    func testGapOver5MinSplitsSession() {
        let f1 = frame(0, bundleID: cursor, title: "a")
        let f2 = frame(60, bundleID: cursor, title: "a")
        let f3 = frame(60 + 301, bundleID: cursor, title: "b")
        let f4 = frame(60 + 361, bundleID: cursor, title: "b")
        let drafts = SessionAggregator.aggregate([f1, f2, f3, f4])
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].id, f1.id)
        XCTAssertEqual(drafts[1].id, f3.id)
    }

    func testDifferentBundleIDSplitsSession() {
        let f1 = frame(0, bundleID: cursor)
        let f2 = frame(60, bundleID: chrome, host: "github.com")
        XCTAssertEqual(SessionAggregator.aggregate([f1, f2]), [])  // both single-frame; both dropped
    }

    func testBrowserHostSplitsSession() {
        let f1 = frame(0, bundleID: chrome, host: "github.com")
        let f2 = frame(60, bundleID: chrome, host: "github.com")
        let f3 = frame(120, bundleID: chrome, host: "twitter.com")
        let f4 = frame(180, bundleID: chrome, host: "twitter.com")
        let drafts = SessionAggregator.aggregate([f1, f2, f3, f4])
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].browserHost, "github.com")
        XCTAssertEqual(drafts[1].browserHost, "twitter.com")
    }

    func testNonBrowserIgnoresHost() {
        // For non-browser bundle, browserURL should be nil from collector;
        // aggregator must not split on URL changes for non-browser frames.
        let f1 = frame(0, bundleID: cursor)
        let f2 = frame(60, bundleID: cursor)
        let drafts = SessionAggregator.aggregate([f1, f2])
        XCTAssertEqual(drafts.count, 1)
        XCTAssertNil(drafts[0].browserHost)
    }

    func testOutOfOrderInputIsSorted() {
        let f1 = frame(0, bundleID: cursor)
        let f2 = frame(60, bundleID: cursor)
        let f3 = frame(120, bundleID: cursor)
        let drafts = SessionAggregator.aggregate([f3, f1, f2])
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].startedAt, f1.observedAt)
        XCTAssertEqual(drafts[0].endedAt, f3.observedAt)
        XCTAssertEqual(drafts[0].id, f1.id)
    }

    func testTitleSamplesMaxFiveDedupSanitizeTrim() {
        // 6 distinct titles + 1 invisible-Cf char + 1 dupe + 1 whitespace-only
        let titles = ["t1", "t2", "t3", "t1", "  ", "t4\u{200B}", "t5", "t6", "t7"]
        let frames = titles.enumerated().map { idx, t in
            frame(TimeInterval(idx * 30), bundleID: cursor, title: t)
        }
        let drafts = SessionAggregator.aggregate(frames)
        XCTAssertEqual(drafts.count, 1)
        let samples = drafts[0].titleSamples
        XCTAssertEqual(samples.count, 5)
        XCTAssertEqual(samples, ["t1", "t2", "t3", "t4", "t5"])  // first-seen order; whitespace-only dropped; ​ stripped; t1 dedup
    }

    func testFrameCountAndFrameIDsPreserveOrder() {
        let f1 = frame(0, bundleID: cursor)
        let f2 = frame(60, bundleID: cursor)
        let f3 = frame(120, bundleID: cursor)
        let drafts = SessionAggregator.aggregate([f3, f2, f1])
        XCTAssertEqual(drafts[0].frameCount, 3)
        XCTAssertEqual(drafts[0].frameIDs, [f1.id, f2.id, f3.id])
    }
}
