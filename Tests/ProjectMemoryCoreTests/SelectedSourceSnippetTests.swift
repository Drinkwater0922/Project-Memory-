import XCTest
@testable import ProjectMemoryCore

final class SelectedSourceSnippetTests: XCTestCase {
    func testActivitySessionCapsDefault() {
        let caps = ActivitySessionCaps.default

        XCTAssertEqual(caps.maxSourcesPerBrief, 4)
        XCTAssertEqual(caps.maxSourcesPerAnswer, 2)
        XCTAssertEqual(caps.maxCharsPerSource, 400)
        XCTAssertEqual(caps.maxTotalBriefActivityChars, 900)
        XCTAssertEqual(caps.maxTotalAnswerActivityChars, 600)
    }

    func testSelectionTotalsDefault() {
        let totals = SelectionTotals.default

        XCTAssertEqual(totals.maxSourcesPerBrief, 12)
        XCTAssertEqual(totals.maxSourcesPerAnswer, 8)
        XCTAssertEqual(totals.maxSourcesPerProject, 3)
    }

    func testSelectedSourceSnippetEquatable() {
        let source = MemorySource(
            projectID: nil,
            kind: .text,
            title: "t",
            path: "/p",
            extractedText: "x",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let a = SelectedSourceSnippet(source: source, snippet: "safe", truncated: false)
        let b = SelectedSourceSnippet(source: source, snippet: "safe", truncated: false)

        XCTAssertEqual(a, b)
    }
}
