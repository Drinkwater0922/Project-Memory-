import XCTest
@testable import ProjectMemoryCore

final class SelectorActivityCapsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func activitySource(
        projectID: UUID,
        offset: TimeInterval,
        longText: Bool = false
    ) -> MemorySource {
        MemorySource(
            projectID: projectID,
            kind: .activitySession,
            title: "Activity",
            path: "activity-sessions/\(UUID().uuidString)",
            extractedText: longText ? String(repeating: "x", count: 600) : "short",
            modifiedAt: now.addingTimeInterval(offset)
        )
    }

    func testBriefActivityKindCap4() {
        let projectID = UUID()
        let project = Project(id: projectID, name: "p", rootPath: "/tmp/p")
        let sources = (0..<6).map { index in
            activitySource(projectID: projectID, offset: TimeInterval(index))
        }

        let snippets = SourceSnippetSelector.selectForBrief(projects: [project], sources: sources)

        XCTAssertLessThanOrEqual(snippets.filter { $0.source.kind == .activitySession }.count, 4)
    }

    func testBriefActivityCharsCap900() {
        let projectID = UUID()
        let project = Project(id: projectID, name: "p", rootPath: "/tmp/p")
        let sources = (0..<4).map { index in
            activitySource(projectID: projectID, offset: TimeInterval(index), longText: true)
        }

        let snippets = SourceSnippetSelector.selectForBrief(projects: [project], sources: sources)
        let activitySnippets = snippets.filter { $0.source.kind == .activitySession }
        let total = activitySnippets.reduce(0) { $0 + $1.snippet.count }

        XCTAssertLessThanOrEqual(total, 900)
    }

    func testAnswerNoProjectExcludesActivity() {
        let projectID = UUID()
        let snippets = SourceSnippetSelector.selectForQuestion(
            [activitySource(projectID: projectID, offset: 0)],
            question: "什么",
            selectedProjectID: nil
        )

        XCTAssertEqual(snippets.filter { $0.source.kind == .activitySession }.count, 0)
    }

    func testAnswerWithProjectFiltersActivity() {
        let projectA = UUID()
        let projectB = UUID()
        let sources = [
            activitySource(projectID: projectA, offset: 0),
            activitySource(projectID: projectB, offset: 1)
        ]

        let snippets = SourceSnippetSelector.selectForQuestion(
            sources,
            question: "什么",
            selectedProjectID: projectA
        )

        XCTAssertEqual(snippets.filter { $0.source.kind == .activitySession }.count, 1)
        XCTAssertEqual(snippets.first { $0.source.kind == .activitySession }?.source.projectID, projectA)
    }

    func testAnswerActivityKindCap2AndChars600() {
        let projectID = UUID()
        let sources = (0..<5).map { index in
            activitySource(projectID: projectID, offset: TimeInterval(index), longText: true)
        }

        let snippets = SourceSnippetSelector.selectForQuestion(
            sources,
            question: "什么",
            selectedProjectID: projectID
        )
        let activitySnippets = snippets.filter { $0.source.kind == .activitySession }

        XCTAssertLessThanOrEqual(activitySnippets.count, 2)
        XCTAssertLessThanOrEqual(activitySnippets.reduce(0) { $0 + $1.snippet.count }, 600)
    }

    func testPerProjectCap3Brief() {
        let project1ID = UUID()
        let project2ID = UUID()
        let project1 = Project(id: project1ID, name: "p1", rootPath: "/p1")
        let project2 = Project(id: project2ID, name: "p2", rootPath: "/p2")
        let project1Sources = (0..<5).map { index in
            MemorySource(
                projectID: project1ID,
                kind: .markdown,
                title: "p1-\(index)",
                path: "/p1/\(index).md",
                extractedText: "x",
                modifiedAt: now.addingTimeInterval(TimeInterval(index))
            )
        }
        let project2Sources = (0..<2).map { index in
            MemorySource(
                projectID: project2ID,
                kind: .markdown,
                title: "p2-\(index)",
                path: "/p2/\(index).md",
                extractedText: "x",
                modifiedAt: now.addingTimeInterval(TimeInterval(index))
            )
        }

        let snippets = SourceSnippetSelector.selectForBrief(
            projects: [project1, project2],
            sources: project1Sources + project2Sources
        )

        XCTAssertLessThanOrEqual(snippets.filter { $0.source.projectID == project1ID }.count, 3)
    }

    func testTruncationMarkerOnLongActivitySnippet() throws {
        let projectID = UUID()
        let project = Project(id: projectID, name: "p", rootPath: "/tmp/p")
        let longSource = activitySource(projectID: projectID, offset: 0, longText: true)

        let snippets = SourceSnippetSelector.selectForBrief(projects: [project], sources: [longSource])
        let snippet = try XCTUnwrap(snippets.first { $0.source.kind == .activitySession })

        XCTAssertTrue(snippet.truncated)
        XCTAssertTrue(snippet.snippet.contains("[内容已截断"))
    }
}
