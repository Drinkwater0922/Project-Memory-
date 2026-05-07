import XCTest

final class PromptPathPrivacyGuardsTests: XCTestCase {
    private let promptPathFiles = [
        "Sources/ProjectMemoryCore/BriefGenerator.swift",
        "Sources/ProjectMemoryCore/AnswerEngine.swift"
    ]

    func testPromptPathDoesNotReferenceActivityFrame() throws {
        for path in promptPathFiles {
            let source = try read(path)
            XCTAssertFalse(source.contains("ActivityFrame"), "\(path) must not reference ActivityFrame")
            XCTAssertFalse(source.contains("activity_frames"), "\(path) must not reference activity_frames")
        }
    }

    func testPromptPathDoesNotReadExtractedText() throws {
        for path in promptPathFiles {
            let source = try read(path)
            XCTAssertFalse(source.contains(".extractedText"), "\(path) must read snippet, not source.extractedText")
        }
    }

    func testSelectorDoesNotTouchActivityFramesTable() throws {
        let source = try read("Sources/ProjectMemoryCore/SourceSnippetSelector.swift")
        XCTAssertFalse(source.contains("ActivityFrame"))
        XCTAssertFalse(source.contains("activity_frames"))
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOfFile: sourcePath(relativePath), encoding: .utf8)
    }

    private func sourcePath(_ relativePath: String) -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent(relativePath).path
    }
}
