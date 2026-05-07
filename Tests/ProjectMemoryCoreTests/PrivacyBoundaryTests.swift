import XCTest
@testable import ProjectMemoryCore
@testable import ProjectMemoryEvalSupport

final class PrivacyBoundaryTests: XCTestCase {
    func testBriefPromptDoesNotContainFullExtractedText() {
        let source = longSource(title: "Long Brief Note")
        let prompt = BriefGenerator.makeDailyBriefPrompt(
            projects: [Project(name: "Alpha", rootPath: "/tmp/alpha")],
            sources: [source],
            events: []
        )

        let results = MechanicalAssertions.assertNoFullExtractedTextLeak(
            prompt: prompt,
            sources: [source]
        )

        XCTAssertAllPass(results)
    }

    func testQuestionPromptDoesNotContainFullExtractedText() {
        let source = longSource(title: "Long Question Note")
        let prompt = AnswerEngine.makeQuestionPrompt(
            question: "privacy",
            sources: [source]
        )

        let results = MechanicalAssertions.assertNoFullExtractedTextLeak(
            prompt: prompt,
            sources: [source]
        )

        XCTAssertAllPass(results)
    }

    func testBriefPromptIncludesTruncationMarkerWhenSourceExceedsLimit() {
        let source = longSource(title: "Long Brief Note")
        let prompt = BriefGenerator.makeDailyBriefPrompt(
            projects: [Project(name: "Alpha", rootPath: "/tmp/alpha")],
            sources: [source],
            events: []
        )

        let results = MechanicalAssertions.assertTruncationMarkerPresent(
            prompt: prompt,
            sources: [source]
        )

        XCTAssertAllPass(results)
    }

    func testQuestionPromptIncludesTruncationMarkerWhenSourceExceedsLimit() {
        let source = longSource(title: "Long Question Note")
        let prompt = AnswerEngine.makeQuestionPrompt(
            question: "privacy",
            sources: [source]
        )

        let results = MechanicalAssertions.assertTruncationMarkerPresent(
            prompt: prompt,
            sources: [source]
        )

        XCTAssertAllPass(results)
    }

    func testBriefSnippetCountWithinCap() {
        let project = Project(name: "Alpha", rootPath: "/tmp/alpha")
        let sources = (0..<13).map { index in
            MemorySource(
                projectID: project.id,
                kind: .markdown,
                title: "Note \(index)",
                path: "/tmp/alpha/\(index).md",
                extractedText: "content \(index)",
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let prompt = BriefGenerator.makeDailyBriefPrompt(
            projects: [project],
            sources: sources,
            events: []
        )

        let results = MechanicalAssertions.assertBriefSnippetCountWithinCap(prompt: prompt)

        XCTAssertAllPass(results)
    }

    func testQuestionSnippetCountWithinCap() {
        let sources = (0..<9).map { index in
            MemorySource(
                projectID: UUID(),
                kind: .markdown,
                title: "Note \(index)",
                path: "/tmp/\(index).md",
                extractedText: "privacy \(index)",
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let prompt = AnswerEngine.makeQuestionPrompt(
            question: "privacy",
            sources: sources
        )

        let results = MechanicalAssertions.assertQuestionSnippetCountWithinCap(prompt: prompt)

        XCTAssertAllPass(results)
    }

    func testCitationFormatTokensPresent() {
        let source = MemorySource(
            projectID: UUID(),
            kind: .webCapture,
            title: "Captured Page",
            path: "/captures/page.txt",
            url: "https://example.com/page",
            extractedText: "captured content",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let prompt = AnswerEngine.makeQuestionPrompt(
            question: "what was captured?",
            sources: [source]
        )

        let results = MechanicalAssertions.assertCitationFormatTokensPresent(prompt: prompt)

        XCTAssertAllPass(results)
    }

    private func longSource(title: String) -> MemorySource {
        MemorySource(
            projectID: UUID(),
            kind: .markdown,
            title: title,
            path: "/tmp/\(title).md",
            extractedText: String(repeating: "private project memory ", count: 100),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func XCTAssertAllPass(
        _ results: [AssertionResult],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(results.isEmpty, file: file, line: line)
        XCTAssertTrue(
            results.allSatisfy(\.passed),
            results.map(\.message).joined(separator: "\n"),
            file: file,
            line: line
        )
    }
}
