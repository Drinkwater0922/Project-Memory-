import Foundation

public struct FolderImportResult: Equatable {
    public let projectID: UUID
    public let warnings: [String]

    public init(projectID: UUID, warnings: [String]) {
        self.projectID = projectID
        self.warnings = warnings
    }
}

public final class FolderImportService {
    public init() {}

    public func importFolder(
        url: URL,
        projectName: String,
        databasePath: String
    ) -> Result<FolderImportResult, Error> {
        do {
            return importFolder(
                url: url,
                projectName: projectName,
                store: try MemoryStore(path: databasePath)
            )
        } catch {
            return .failure(error)
        }
    }

    public func importFolder(
        url: URL,
        projectName: String,
        store: MemoryStore
    ) -> Result<FolderImportResult, Error> {
        var warnings: [String] = []

        do {
            let project = try store.findProject(rootPath: url.path)
                ?? Project(name: projectName, rootPath: url.path)
            try store.saveProject(project)

            let scanner = SourceScanner()
            let parser = SourceParser()
            let fileURLs = try scanner.scan(root: url)

            for fileURL in fileURLs {
                do {
                    let data = try Data(contentsOf: fileURL)
                    let extractedText = try parser.extractText(
                        from: data,
                        fileExtension: fileURL.pathExtension
                    )
                    let modifiedAt = fileURL.contentModificationDate ?? Date()
                    let existing = try store.findSource(projectID: project.id, path: fileURL.path)
                    let source = MemorySource(
                        id: existing?.id ?? UUID(),
                        projectID: project.id,
                        kind: scanner.kind(for: fileURL),
                        title: TextSanitizer.stripInvisibleControls(fileURL.lastPathComponent),
                        path: fileURL.path,
                        extractedText: TextSanitizer.stripInvisibleControls(extractedText),
                        modifiedAt: modifiedAt
                    )

                    try store.saveSource(source)
                    try store.saveTimelineEvent(
                        TimelineEvent(
                            projectID: project.id,
                            sourceID: source.id,
                            kind: .sourceAdded,
                            title: "Source added",
                            summary: fileURL.path,
                            occurredAt: modifiedAt
                        )
                    )
                } catch {
                    warnings.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }

            do {
                let gitEvents = try GitActivityReader().recentEvents(project: project)
                for event in gitEvents {
                    try store.saveTimelineEvent(event)
                }
            } catch {
                warnings.append("Git activity: \(error.localizedDescription)")
            }

            return .success(FolderImportResult(projectID: project.id, warnings: warnings))
        } catch {
            return .failure(error)
        }
    }
}

private extension URL {
    var contentModificationDate: Date? {
        try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
