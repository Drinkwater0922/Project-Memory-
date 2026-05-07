import XCTest

/// Future-proof guard: scan BriefGenerator.swift and AnswerEngine.swift source bytes
/// to ensure they never reference activity_frames data structures. This is a
/// stronger guard than BriefGeneratorIsolationTests because it doesn't depend on
/// any input/store wiring — it scans the source code directly.
final class CoreSourceLeakGuardTests: XCTestCase {
    func testBriefGeneratorSourceDoesNotReferenceActivity() throws {
        try assertSourceContainsNoActivityReferences(filename: "BriefGenerator.swift")
    }

    func testAnswerEngineSourceDoesNotReferenceActivity() throws {
        try assertSourceContainsNoActivityReferences(filename: "AnswerEngine.swift")
    }

    private func assertSourceContainsNoActivityReferences(
        filename: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // Test file is at <repo>/Tests/ProjectMemoryCoreTests/CoreSourceLeakGuardTests.swift
        // Walk up to repo root, then into Sources/ProjectMemoryCore/
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()  // ProjectMemoryCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
        let target = repoRoot
            .appendingPathComponent("Sources/ProjectMemoryCore")
            .appendingPathComponent(filename)

        let source = try String(contentsOf: target, encoding: .utf8)

        let forbidden = ["ActivityFrame", "ActivityCategory", "ActivityCandidate", "activity_frames"]
        for needle in forbidden {
            XCTAssertFalse(
                source.contains(needle),
                "\(filename) must not reference '\(needle)' — Phase 1 isolates activity data from brief / Q&A.",
                file: file,
                line: line
            )
        }
    }
}
