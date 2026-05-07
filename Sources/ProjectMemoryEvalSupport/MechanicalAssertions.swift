import Foundation
import ProjectMemoryCore

public struct AssertionResult: Equatable {
    public let name: String
    public let passed: Bool
    public let message: String

    public init(name: String, passed: Bool, message: String) {
        self.name = name
        self.passed = passed
        self.message = message
    }
}

public enum MechanicalAssertions {
    public static let defaultSnippetMaxLength = 1_200
    public static let defaultBriefSourceCap = 12
    public static let defaultQuestionSourceCap = 8
    public static let truncationMarker = "[内容已截断，仅发送相关片段]"

    public static func assertNoFullExtractedTextLeak(
        prompt: String,
        sources: [MemorySource],
        snippetMaxLength: Int = defaultSnippetMaxLength
    ) -> [AssertionResult] {
        let leakingSources = sources
            .filter { $0.extractedText.count > snippetMaxLength }
            .filter { prompt.contains($0.extractedText) }
            .map(\.title)

        return [
            AssertionResult(
                name: "privacy_no_full_extractedtext",
                passed: leakingSources.isEmpty,
                message: leakingSources.isEmpty
                    ? "Prompt does not contain full extractedText for oversized sources."
                    : "Prompt leaks full extractedText for sources: \(leakingSources.joined(separator: ", "))"
            )
        ]
    }

    public static func assertTruncationMarkerPresent(
        prompt: String,
        sources: [MemorySource],
        snippetMaxLength: Int = defaultSnippetMaxLength
    ) -> [AssertionResult] {
        let oversizedCount = sources.filter { $0.extractedText.count > snippetMaxLength }.count
        let markerCount = prompt.occurrenceCount(of: truncationMarker)
        let passed = oversizedCount == 0 || markerCount >= oversizedCount

        return [
            AssertionResult(
                name: "privacy_truncation_marker_present",
                passed: passed,
                message: passed
                    ? "Prompt contains truncation markers for oversized sources."
                    : "Prompt has \(markerCount) truncation marker(s), expected at least \(oversizedCount)."
            )
        ]
    }

    public static func assertBriefSnippetCountWithinCap(
        prompt: String,
        maxCount: Int = defaultBriefSourceCap
    ) -> [AssertionResult] {
        assertSnippetCountWithinCap(prompt: prompt, maxCount: maxCount)
    }

    public static func assertQuestionSnippetCountWithinCap(
        prompt: String,
        maxCount: Int = defaultQuestionSourceCap
    ) -> [AssertionResult] {
        assertSnippetCountWithinCap(prompt: prompt, maxCount: maxCount)
    }

    public static func assertCitationFormatTokensPresent(prompt: String) -> [AssertionResult] {
        let missingTokens = ["路径：", "URL："].filter { !prompt.contains($0) }

        return [
            AssertionResult(
                name: "citation_format_present",
                passed: missingTokens.isEmpty,
                message: missingTokens.isEmpty
                    ? "Prompt contains citation format tokens."
                    : "Prompt is missing citation format token(s): \(missingTokens.joined(separator: ", "))"
            )
        ]
    }

    private static func assertSnippetCountWithinCap(
        prompt: String,
        maxCount: Int
    ) -> [AssertionResult] {
        let sourceBlockCount = prompt.occurrenceCount(of: "- 来源：《")
        return [
            AssertionResult(
                name: "snippet_count_within_cap",
                passed: sourceBlockCount <= maxCount,
                message: sourceBlockCount <= maxCount
                    ? "Prompt contains \(sourceBlockCount) source block(s), cap is \(maxCount)."
                    : "Prompt contains \(sourceBlockCount) source block(s), cap is \(maxCount)."
            )
        ]
    }
}

private extension String {
    func occurrenceCount(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }

        var count = 0
        var searchRange = startIndex..<endIndex
        while let range = range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<endIndex
        }
        return count
    }
}
