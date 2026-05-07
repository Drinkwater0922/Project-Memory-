import XCTest
@testable import ProjectMemoryCore

final class BriefGeneratorIsolationTests: XCTestCase {
    func testDailyBriefPromptDoesNotIncludeActivityFrameContent() throws {
        let store = try MemoryStore.inMemory()
        try store.saveActivityFrame(
            ActivityFrame(
                observedAt: Date(timeIntervalSince1970: 1),
                bundleID: "com.tinyspeck.slackmacgap",
                appName: "Slack",
                windowTitle: "私人对话 alice",
                browserURL: nil,
                category: .chat,
                projectID: nil
            )
        )
        try store.saveActivityFrame(
            ActivityFrame(
                observedAt: Date(timeIntervalSince1970: 2),
                bundleID: "com.google.Chrome",
                appName: "Chrome",
                windowTitle: nil,
                browserURL: "https://example.com/secret",
                category: .other,
                projectID: nil
            )
        )

        let prompt = BriefGenerator.makeDailyBriefPrompt(
            projects: [],
            sources: [],
            events: []
        )

        XCTAssertFalse(prompt.contains("com.tinyspeck.slackmacgap"))
        XCTAssertFalse(prompt.contains("私人对话 alice"))
        XCTAssertFalse(prompt.contains("https://example.com/secret"))
        XCTAssertFalse(prompt.contains("com.google.Chrome"))
    }
}
