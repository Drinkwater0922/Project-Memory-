import Foundation

public struct AnswerEngine {
    public init() {}

    public static func makeQuestionPrompt(question: String, sources: [MemorySource]) -> String {
        AnswerEngine().makeQuestionPrompt(question: question, sources: sources)
    }

    public func makeQuestionPrompt(question: String, sources: [MemorySource]) -> String {
        """
        请用中文回答问题，并严格遵守：
        - 只能根据下面列出的来源回答。
        - 如果来源证据不足，请回答“证据不足”，并说明还缺少什么信息。
        - 回答中必须引用来源标题、路径和 URL；没有 URL 时写“URL：无”。
        - 不要编造未在来源中出现的事实。

        问题：
        \(question)

        来源片段（已在本地按问题相关性筛选并截断，不代表完整文件）：
        \(formatSources(SourceSnippetSelector.selectForQuestion(sources, question: question)))
        """
    }

    private func formatSources(_ sources: [MemorySource]) -> String {
        guard !sources.isEmpty else {
            return "- 无来源证据"
        }

        return sources.map { source in
            """
            - 来源：《\(source.title)》
              路径：\(source.path)
              URL：\(source.url ?? "无")
              内容片段：\(SourceSnippetSelector.snippet(source.extractedText))
            """
        }.joined(separator: "\n")
    }
}
