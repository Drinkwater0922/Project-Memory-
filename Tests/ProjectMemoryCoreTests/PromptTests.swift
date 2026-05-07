import XCTest
@testable import ProjectMemoryCore

final class PromptTests: XCTestCase {
    func testDailyBriefPromptIncludesProjectSourceEvidenceAndChineseSourceWording() {
        let project = Project(
            name: "Project Memory",
            rootPath: "/tmp/project-memory",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let source = MemorySource(
            projectID: project.id,
            kind: .markdown,
            title: "MVP Plan",
            path: "/tmp/project-memory/docs/plan.md",
            extractedText: "TODO: wire daily brief UI and review open questions.",
            modifiedAt: Date(timeIntervalSince1970: 101)
        )
        let event = TimelineEvent(
            projectID: project.id,
            sourceID: source.id,
            kind: .sourceUpdated,
            title: "Plan updated",
            summary: "Added prompt generation task.",
            occurredAt: Date(timeIntervalSince1970: 102)
        )

        let prompt = BriefGenerator().makeDailyBriefPrompt(
            projects: [project],
            sources: [source],
            events: [event]
        )

        XCTAssertTrue(prompt.contains("Project Memory"))
        XCTAssertTrue(prompt.contains("MVP Plan"))
        XCTAssertTrue(prompt.contains("/tmp/project-memory/docs/plan.md"))
        XCTAssertTrue(prompt.contains("TODO: wire daily brief UI and review open questions."))
        XCTAssertTrue(prompt.contains("来源"))
        XCTAssertTrue(prompt.contains("1-3 个下一步行动"))
        XCTAssertTrue(prompt.contains("不要编造事实"))
        XCTAssertTrue(prompt.contains("Plan updated"))
        XCTAssertTrue(prompt.contains("Added prompt generation task."))
        XCTAssertTrue(prompt.contains("已在本地按项目配额和最近修改筛选并截断"))
        XCTAssertTrue(prompt.contains("必须逐个覆盖"))
    }

    func testQuestionPromptIncludesQuestionSourceTextAndURL() {
        let source = MemorySource(
            projectID: UUID(),
            kind: .webCapture,
            title: "OpenRouter Notes",
            path: "/captures/openrouter.txt",
            url: "https://example.com/openrouter-notes",
            extractedText: "OpenRouter responses should be grounded in listed project sources.",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let prompt = AnswerEngine().makeQuestionPrompt(
            question: "How should answers handle missing evidence?",
            sources: [source]
        )

        XCTAssertTrue(prompt.contains("How should answers handle missing evidence?"))
        XCTAssertTrue(prompt.contains("OpenRouter responses should be grounded in listed project sources."))
        XCTAssertTrue(prompt.contains("https://example.com/openrouter-notes"))
        XCTAssertTrue(prompt.contains("OpenRouter Notes"))
        XCTAssertTrue(prompt.contains("/captures/openrouter.txt"))
        XCTAssertTrue(prompt.contains("证据不足"))
    }

    func testQuestionPromptDoesNotIncludeFullLongSourceText() {
        let longText = String(repeating: "sensitive project detail ", count: 200)
        let source = MemorySource(
            projectID: UUID(),
            kind: .markdown,
            title: "Long Note",
            path: "/tmp/long.md",
            extractedText: longText,
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let prompt = AnswerEngine().makeQuestionPrompt(
            question: "project detail",
            sources: [source]
        )

        XCTAssertTrue(prompt.contains("[内容已截断，仅发送相关片段]"))
        XCTAssertFalse(prompt.contains(longText))
    }
}
