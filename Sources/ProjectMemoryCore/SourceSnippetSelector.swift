import Foundation

public enum SourceSnippetSelector {
    public static func selectForBrief(_ sources: [MemorySource], limit: Int = 12) -> [MemorySource] {
        Array(
            sources
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(limit)
        )
    }

    public static func selectForBrief(
        projects: [Project],
        sources: [MemorySource],
        limit: Int = 12,
        perProjectLimit: Int = 3
    ) -> [MemorySource] {
        var selected: [MemorySource] = []
        var selectedIDs = Set<UUID>()

        for project in projects {
            let projectSources = sources
                .filter { $0.projectID == project.id }
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(perProjectLimit)
            for source in projectSources where selected.count < limit {
                selected.append(source)
                selectedIDs.insert(source.id)
            }
        }

        let remaining = sources
            .filter { !selectedIDs.contains($0.id) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(max(0, limit - selected.count))
        selected.append(contentsOf: remaining)

        return selected
    }

    public static func selectForQuestion(
        _ sources: [MemorySource],
        question: String,
        limit: Int = 8
    ) -> [MemorySource] {
        let terms = Set(
            question
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 2 }
        )

        return Array(
            sources
                .map { source in
                    (source: source, score: score(source: source, terms: terms))
                }
                .sorted {
                    if $0.score == $1.score {
                        return $0.source.modifiedAt > $1.source.modifiedAt
                    }
                    return $0.score > $1.score
                }
                .prefix(limit)
                .map(\.source)
        )
    }

    public static func snippet(_ text: String, maxLength: Int = 1200) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else {
            return trimmed
        }
        return String(trimmed.prefix(maxLength)) + "\n[内容已截断，仅发送相关片段]"
    }

    private static func score(source: MemorySource, terms: Set<String>) -> Int {
        guard !terms.isEmpty else { return 0 }
        let haystack = "\(source.title) \(source.path) \(source.url ?? "") \(source.extractedText)"
            .lowercased()
        return terms.reduce(0) { partial, term in
            haystack.contains(term) ? partial + 1 : partial
        }
    }
}
