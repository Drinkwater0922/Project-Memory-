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
        let activity = sources
            .filter { $0.kind == .activitySession }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(caps.maxSourcesPerBrief)
        let other = sources.filter { $0.kind != .activitySession }

        var nonActivitySelected: [MemorySource] = []
        var selectedIDs = Set<UUID>()
        for project in projects {
            let projectSources = other
                .filter { $0.projectID == project.id }
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(totals.maxSourcesPerProject)
            for source in projectSources {
                nonActivitySelected.append(source)
                selectedIDs.insert(source.id)
            }
        }

        let remaining = sources
            .filter { $0.kind != .activitySession }
            .filter { !selectedIDs.contains($0.id) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        nonActivitySelected.append(contentsOf: remaining)

        var merged = Array(activity) + nonActivitySelected
        merged.sort { $0.modifiedAt > $1.modifiedAt }

        let afterPerProject = applyPerProjectCap(merged, cap: totals.maxSourcesPerProject)
        let limited = Array(afterPerProject.prefix(totals.maxSourcesPerBrief))
        let snippets = limited.map { makeSnippet(for: $0, caps: caps) }
        return applyActivityCharCap(snippets, totalChars: caps.maxTotalBriefActivityChars)
    }

    public static func selectForQuestion(
        _ sources: [MemorySource],
        question: String,
        selectedProjectID: UUID? = nil,
        totals: SelectionTotals = .default,
        caps: ActivitySessionCaps = .default
    ) -> [SelectedSourceSnippet] {
        let activity: [MemorySource]
        if let selectedProjectID {
            activity = sources
                .filter { $0.kind == .activitySession && $0.projectID == selectedProjectID }
                .sorted { $0.modifiedAt > $1.modifiedAt }
        } else {
            activity = []
        }
        let cappedActivity = activity.prefix(caps.maxSourcesPerAnswer)
        let other = sources.filter { $0.kind != .activitySession }
        let terms = Set(
            question
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 2 }
        )

        let scoredOther = other
            .map { source in
                (source: source, score: score(source: source, terms: terms))
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.source.modifiedAt > $1.source.modifiedAt
                }
                return $0.score > $1.score
            }
            .map(\.source)

        let merged = Array(cappedActivity) + scoredOther
        let afterPerProject = applyPerProjectCap(merged, cap: totals.maxSourcesPerProject)
        let limited = Array(afterPerProject.prefix(totals.maxSourcesPerAnswer))
        let snippets = limited.map { makeSnippet(for: $0, caps: caps) }
        return applyActivityCharCap(snippets, totalChars: caps.maxTotalAnswerActivityChars)
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

    private static func applyPerProjectCap(_ sources: [MemorySource], cap: Int) -> [MemorySource] {
        var counts: [UUID?: Int] = [:]
        var selected: [MemorySource] = []
        for source in sources {
            let count = counts[source.projectID, default: 0]
            guard count < cap else {
                continue
            }
            selected.append(source)
            counts[source.projectID] = count + 1
        }
        return selected
    }

    private static func applyActivityCharCap(
        _ snippets: [SelectedSourceSnippet],
        totalChars: Int
    ) -> [SelectedSourceSnippet] {
        var activityTotal = 0
        var keptActivityIDs = Set<UUID>()
        let activitySnippets = snippets
            .filter { $0.source.kind == .activitySession }
            .sorted { $0.source.modifiedAt > $1.source.modifiedAt }

        for snippet in activitySnippets {
            guard activityTotal + snippet.snippet.count <= totalChars else {
                continue
            }
            keptActivityIDs.insert(snippet.source.id)
            activityTotal += snippet.snippet.count
        }

        return snippets.filter { snippet in
            snippet.source.kind != .activitySession || keptActivityIDs.contains(snippet.source.id)
        }
    }
}
