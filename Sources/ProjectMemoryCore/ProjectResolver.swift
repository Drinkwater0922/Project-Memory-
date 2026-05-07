import Foundation

public final class ProjectResolver {
    private let entries: [(project: Project, standardizedRoot: String)]

    public init(projects: [Project]) {
        self.entries = projects.map { project in
            (project, URL(fileURLWithPath: project.rootPath).standardizedFileURL.path)
        }
    }

    public func resolve(path: String) -> UUID? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path

        return entries
            .sorted { $0.standardizedRoot.count > $1.standardizedRoot.count }
            .first { entry in
                let root = entry.standardizedRoot
                return standardized == root || standardized.hasPrefix(root + "/")
            }?
            .project
            .id
    }
}
