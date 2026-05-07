import XCTest
@testable import ProjectMemoryCore

final class SourceSnippetSelectorTests: XCTestCase {
    func testSelectForBriefReturnsMostRecentTwelveSources() {
        let sources = (0..<13).map { index in
            MemorySource(
                projectID: UUID(),
                kind: .markdown,
                title: "Source \(index)",
                path: "/tmp/\(index).md",
                extractedText: "content",
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let selected = SourceSnippetSelector.selectForBrief(sources)

        XCTAssertEqual(selected.count, 12)
        XCTAssertEqual(selected.first?.source.title, "Source 12")
        XCTAssertFalse(selected.contains { $0.source.title == "Source 0" })
        XCTAssertTrue(selected.allSatisfy { $0.snippet == "content" && !$0.truncated })
    }

    func testSelectForBriefIncludesSourcesFromEachProject() {
        let productProject = Project(name: "Product Insights", rootPath: "/tmp/product")
        let meetingProject = Project(name: "Meetings", rootPath: "/tmp/meetings")
        let productSources = (0..<12).map { index in
            MemorySource(
                projectID: productProject.id,
                kind: .markdown,
                title: "Product \(index)",
                path: "/tmp/product/\(index).md",
                extractedText: "product",
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(100 + index))
            )
        }
        let meetingSources = (0..<2).map { index in
            MemorySource(
                projectID: meetingProject.id,
                kind: .markdown,
                title: "Meeting \(index)",
                path: "/tmp/meetings/\(index).md",
                extractedText: "meeting",
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let selected = SourceSnippetSelector.selectForBrief(
            projects: [productProject, meetingProject],
            sources: productSources + meetingSources,
            totals: SelectionTotals(
                maxSourcesPerBrief: 6,
                maxSourcesPerAnswer: SelectionTotals.default.maxSourcesPerAnswer,
                maxSourcesPerProject: 2
            )
        )

        XCTAssertEqual(selected.count, 4)
        XCTAssertTrue(selected.contains { $0.source.projectID == productProject.id })
        XCTAssertTrue(selected.contains { $0.source.projectID == meetingProject.id })
        XCTAssertEqual(selected.filter { $0.source.projectID == meetingProject.id }.count, 2)
        XCTAssertTrue(selected.allSatisfy { !$0.snippet.isEmpty && !$0.truncated })
    }

    func testSelectForQuestionPrioritizesKeywordMatchOverRecency() {
        let matchingOlder = MemorySource(
            projectID: UUID(),
            kind: .markdown,
            title: "Architecture Note",
            path: "/tmp/architecture.md",
            extractedText: "retrieval privacy",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let newerNonMatch = MemorySource(
            projectID: UUID(),
            kind: .markdown,
            title: "Recent Note",
            path: "/tmp/recent.md",
            extractedText: "unrelated",
            modifiedAt: Date(timeIntervalSince1970: 2)
        )

        let selected = SourceSnippetSelector.selectForQuestion(
            [newerNonMatch, matchingOlder],
            question: "privacy retrieval"
        )

        XCTAssertEqual(selected.first?.source.id, matchingOlder.id)
        XCTAssertEqual(selected.first?.snippet, "retrieval privacy")
        XCTAssertEqual(selected.first?.truncated, false)
    }

    func testSnippetBoundaryAndTruncationMarker() {
        let exact = String(repeating: "a", count: 10)
        XCTAssertEqual(SourceSnippetSelector.snippet(exact, maxLength: 10), exact)

        let long = String(repeating: "b", count: 11)
        let snippet = SourceSnippetSelector.snippet(long, maxLength: 10)
        XCTAssertTrue(snippet.hasPrefix(String(repeating: "b", count: 10)))
        XCTAssertTrue(snippet.contains("[内容已截断，仅发送相关片段]"))
    }
}
