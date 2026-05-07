import XCTest
@testable import ProjectMemoryCore

final class PromptPathSentinelTests: XCTestCase {
    func testBriefBuildPromptOnlyReadsSnippetNotSourceExtractedText() {
        let leak = "LEAK_SENTINEL_\(UUID().uuidString)"
        let safe = "SAFE_SNIPPET_\(UUID().uuidString)"
        let source = MemorySource(
            projectID: nil,
            kind: .markdown,
            title: "t",
            path: "/p",
            extractedText: leak,
            modifiedAt: Date()
        )
        let snippet = SelectedSourceSnippet(source: source, snippet: safe, truncated: false)

        let prompt = BriefGenerator.buildPrompt(projects: [], snippets: [snippet], events: [])

        XCTAssertTrue(prompt.contains(safe))
        XCTAssertFalse(prompt.contains(leak))
    }

    func testAnswerBuildPromptOnlyReadsSnippetNotSourceExtractedText() {
        let leak = "LEAK_SENTINEL_\(UUID().uuidString)"
        let safe = "SAFE_SNIPPET_\(UUID().uuidString)"
        let source = MemorySource(
            projectID: nil,
            kind: .markdown,
            title: "t",
            path: "/p",
            extractedText: leak,
            modifiedAt: Date()
        )
        let snippet = SelectedSourceSnippet(source: source, snippet: safe, truncated: false)

        let prompt = AnswerEngine.buildPrompt(question: "Q?", snippets: [snippet])

        XCTAssertTrue(prompt.contains(safe))
        XCTAssertFalse(prompt.contains(leak))
    }

    func testAnswerPromptNeverContainsActivityFromOtherProject() {
        let projectA = UUID()
        let projectB = UUID()
        let marker = "OTHER_PROJECT_HOST_\(UUID().uuidString)"
        let now = Date()
        let activityA = MemorySource(
            projectID: projectA,
            kind: .activitySession,
            title: "A",
            path: "activity-sessions/\(UUID().uuidString)",
            extractedText: "应用：X\n网址：project-a.example.com",
            modifiedAt: now
        )
        let activityB = MemorySource(
            projectID: projectB,
            kind: .activitySession,
            title: "B",
            path: "activity-sessions/\(UUID().uuidString)",
            extractedText: "应用：X\n网址：\(marker)",
            modifiedAt: now
        )

        let prompt = AnswerEngine.makeQuestionPrompt(
            question: "进度",
            sources: [activityA, activityB],
            selectedProjectID: projectA
        )

        XCTAssertTrue(prompt.contains("project-a.example.com"))
        XCTAssertFalse(prompt.contains(marker))
    }

    func testAnswerPromptNoActivityWhenNoProjectSelected() {
        let projectID = UUID()
        let marker = "NO_PROJECT_MARKER_\(UUID().uuidString)"
        let activity = MemorySource(
            projectID: projectID,
            kind: .activitySession,
            title: "A",
            path: "activity-sessions/\(UUID().uuidString)",
            extractedText: marker,
            modifiedAt: Date()
        )

        let prompt = AnswerEngine.makeQuestionPrompt(
            question: "问题",
            sources: [activity],
            selectedProjectID: nil
        )

        XCTAssertFalse(prompt.contains(marker))
    }
}
