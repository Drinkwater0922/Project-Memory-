import XCTest
@testable import ProjectMemoryCore

final class GitActivityReaderTests: XCTestCase {
    func testRecentEventsReturnsEmptyForNonGitProject() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = Project(name: "No Git", rootPath: root.path)
        let events = try GitActivityReader().recentEvents(project: project, limit: 5)

        XCTAssertEqual(events, [])
    }

    func testRecentEventsReadsLatestGitCommit() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["-C", root.path, "init"])
        try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try runGit(["-C", root.path, "add", "note.txt"])
        try runGit(
            [
                "-C",
                root.path,
                "-c",
                "user.name=Project Memory Tests",
                "-c",
                "user.email=tests@example.com",
                "commit",
                "-m",
                "Capture project context"
            ],
            environment: [
                "GIT_AUTHOR_DATE": "2026-05-06T12:34:56+08:00",
                "GIT_COMMITTER_DATE": "2026-05-06T12:34:56+08:00"
            ]
        )
        let hash = try runGit(["-C", root.path, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let project = Project(name: "Git Project", rootPath: root.path)
        let events = try GitActivityReader().recentEvents(project: project, limit: 1)

        let commit = try XCTUnwrap(events.first { $0.kind == .gitCommit })
        XCTAssertEqual(commit.projectID, project.id)
        XCTAssertNil(commit.sourceID)
        XCTAssertEqual(commit.title, "Capture project context")
        XCTAssertEqual(commit.summary, "Commit \(hash.prefix(8)): Capture project context")
        XCTAssertEqual(commit.occurredAt.timeIntervalSince1970, 1_778_042_096, accuracy: 0.001)
        XCTAssertTrue(events.contains { $0.title.hasPrefix("Current branch:") })
    }

    func testRecentEventsIncludesUncommittedWorkingTreeStatus() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["-C", root.path, "init"])
        try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try runGit(["-C", root.path, "add", "note.txt"])
        try runGit(
            [
                "-C",
                root.path,
                "-c",
                "user.name=Project Memory Tests",
                "-c",
                "user.email=tests@example.com",
                "commit",
                "-m",
                "Initial note"
            ]
        )
        try "hello\nchanged".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let project = Project(name: "Git Project", rootPath: root.path)
        let events = try GitActivityReader().recentEvents(project: project, limit: 1)
        let workingTree = try XCTUnwrap(events.first { $0.title == "Uncommitted Git changes" })

        XCTAssertTrue(workingTree.summary.contains("Working tree status"))
        XCTAssertTrue(workingTree.summary.contains("Diff stat"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func runGit(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(data: error, encoding: .utf8) ?? ""
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(message)")
        }

        return String(data: output, encoding: .utf8) ?? ""
    }
}
