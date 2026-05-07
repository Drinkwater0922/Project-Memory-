import Foundation

public enum GitActivityReaderError: Error, Equatable {
    case gitFailed(status: Int32)
}

public final class GitActivityReader {
    private let dateFormatter: ISO8601DateFormatter

    public init() {
        dateFormatter = ISO8601DateFormatter()
    }

    public func recentEvents(project: Project, limit: Int = 20) throws -> [TimelineEvent] {
        guard limit > 0 else { return [] }

        let repo = URL(fileURLWithPath: project.rootPath)
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) else {
            return []
        }

        var events = try workingTreeEvents(project: project, repo: repo)
        events.append(
            contentsOf: parseCommitEvents(
                output: try runGit(
                    arguments: [
                        "log",
                        "--pretty=format:%H%x1f%ad%x1f%s",
                        "--date=iso-strict",
                        "-n",
                        "\(limit)"
                    ],
                    directory: repo
                ),
                project: project
            )
        )
        return events
    }

    private func parseCommitEvents(output: String, project: Project) -> [TimelineEvent] {
        output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                guard parts.count == 3 else { return nil }

                let hash = String(parts[0])
                let occurredAt = dateFormatter.date(from: String(parts[1])) ?? Date()
                let subject = String(parts[2])

                return TimelineEvent(
                    projectID: project.id,
                    sourceID: nil,
                    kind: .gitCommit,
                    title: subject,
                    summary: "Commit \(hash.prefix(8)): \(subject)",
                    occurredAt: occurredAt
                )
            }
    }

    private func workingTreeEvents(project: Project, repo: URL) throws -> [TimelineEvent] {
        let branch = try runGit(arguments: ["branch", "--show-current"], directory: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = try runGit(arguments: ["status", "--short"], directory: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let diffStat = try runGit(arguments: ["diff", "--stat"], directory: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var events: [TimelineEvent] = []
        if !branch.isEmpty {
            events.append(
                TimelineEvent(
                    projectID: project.id,
                    sourceID: nil,
                    kind: .sourceUpdated,
                    title: "Current branch: \(branch)",
                    summary: "Git branch: \(branch)",
                    occurredAt: Date()
                )
            )
        }

        if !status.isEmpty || !diffStat.isEmpty {
            let summary = [
                status.isEmpty ? nil : "Working tree status:\n\(status)",
                diffStat.isEmpty ? nil : "Diff stat:\n\(diffStat)"
            ]
                .compactMap { $0 }
                .joined(separator: "\n\n")
            events.append(
                TimelineEvent(
                    projectID: project.id,
                    sourceID: nil,
                    kind: .sourceUpdated,
                    title: "Uncommitted Git changes",
                    summary: summary,
                    occurredAt: Date()
                )
            )
        }

        return events
    }

    private func runGit(arguments: [String], directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw GitActivityReaderError.gitFailed(status: process.terminationStatus)
        }

        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
