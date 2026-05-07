import XCTest
@testable import ProjectMemoryApp

@MainActor
final class SessionPipelineWindowTests: XCTestCase {
    func testBriefAnswerAndTriageWindowsUseExpectedLookbacks() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(SessionPipeline.briefWindow(now: now).start, now.addingTimeInterval(-24 * 3600))
        XCTAssertEqual(SessionPipeline.briefWindow(now: now).end, now)

        XCTAssertEqual(SessionPipeline.answerWindow(now: now).start, now.addingTimeInterval(-7 * 24 * 3600))
        XCTAssertEqual(SessionPipeline.answerWindow(now: now).end, now)

        XCTAssertEqual(SessionPipeline.triageWindow(now: now).start, now.addingTimeInterval(-7 * 24 * 3600))
        XCTAssertEqual(SessionPipeline.triageWindow(now: now).end, now)
    }
}
