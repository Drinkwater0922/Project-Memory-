import Foundation

public enum SourceSnippetSelector {
    public static let nonActivityCharCap = 1_200
    public static let truncationMarker = "\n[内容已截断，仅发送相关片段]"

    public static func selectForBrief(
        _ sources: [MemorySource],
        limit: Int = SelectionTotals.default.maxSourcesPerBrief,
        caps: ActivitySessionCaps = .default
    ) -> [SelectedSourceSnippet] {
        let totals = SelectionTotals(
            maxSourcesPerBrief: limit,
            maxSourcesPerAnswer: SelectionTotals.default.maxSourcesPerAnswer,
            maxSourcesPerProject: SelectionTotals.default.maxSourcesPerProject
        )
        return selectForBrief(projects: [], sources: sources, totals: totals, caps: caps)
    }

    public static func selectForBrief(
        projects: [Project],
        sources: [MemorySource],
        totals: SelectionTotals = .default,
        caps: ActivitySessionCaps = .default
    ) -> [SelectedSourceSnippet] {
        let limit = totals.maxSourcesPerBrief
        let perProjectLimit = totals.maxSourcesPerProject

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

        return selected.map { makeSnippet(for: $0, caps: caps) }
    }

    public static func selectForQuestion(
        _ sources: [MemorySource],
        question: String,
        selectedProjectID: UUID? = nil,
        totals: SelectionTotals = .default,
        caps: ActivitySessionCaps = .default
    ) -> [SelectedSourceSnippet] {
        let filtered = sources.filter { source in
            guard source.kind == .activitySession else {
                return true
            }
            guard let selectedProjectID else {
                return false
            }
            return source.projectID == selectedProjectID
        }
        let terms = Set(
            question
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 2 }
        )

        let selected = filtered
            .map { source in
                (source: source, score: score(source: source, terms: terms))
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.source.modifiedAt > $1.source.modifiedAt
                }
                return $0.score > $1.score
            }
            .prefix(totals.maxSourcesPerAnswer)
            .map(\.source)

        return selected.map { makeSnippet(for: $0, caps: caps) }
    }

    public static func snippet(_ text: String, maxLength: Int = nonActivityCharCap) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else {
            return trimmed
        }
        return String(trimmed.prefix(maxLength)) + truncationMarker
    }

    static func makeSnippet(for source: MemorySource, caps: ActivitySessionCaps) -> SelectedSourceSnippet {
        let cap = source.kind == .activitySession ? caps.maxCharsPerSource : nonActivityCharCap
        let trimmed = source.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > cap else {
            return SelectedSourceSnippet(source: source, snippet: trimmed, truncated: false)
        }

        return SelectedSourceSnippet(
            source: source,
            snippet: String(trimmed.prefix(cap)) + truncationMarker,
            truncated: true
        )
    }

    private static func score(source: MemorySource, terms: Set<String>) -> Int {
        guard !terms.isEmpty else {
            return 0
        }
        let haystack = "\(source.title) \(source.path) \(source.url ?? "") \(source.extractedText)"
            .lowercased()
        return terms.reduce(0) { partial, term in
            haystack.contains(term) ? partial + 1 : partial
        }
    }
}
