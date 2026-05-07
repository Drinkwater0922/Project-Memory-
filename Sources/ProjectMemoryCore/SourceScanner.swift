import Foundation

public final class SourceScanner {
    private let supportedExtensions = Set(["md", "markdown", "txt", "pdf", "html", "htm"])

    public init() {}

    public func scan(root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey]) else {
                continue
            }
            if values.isPackage == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                continue
            }
            urls.append(url)
        }

        return urls.sorted { $0.path < $1.path }
    }

    public func kind(for url: URL) -> SourceKind {
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            return .markdown
        case "txt":
            return .text
        case "pdf":
            return .pdf
        case "html", "htm":
            return .html
        default:
            return .unsupported
        }
    }
}
