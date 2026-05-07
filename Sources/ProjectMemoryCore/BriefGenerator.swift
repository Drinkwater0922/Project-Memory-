import Foundation

public struct BriefGenerator {
    public init() {}

    public static func makeDailyBriefPrompt(
        projects: [Project],
        sources: [MemorySource],
        events: [TimelineEvent]
    ) -> String {
        BriefGenerator().makeDailyBriefPrompt(projects: projects, sources: sources, events: events)
    }

    public func makeDailyBriefPrompt(
        projects: [Project],
        sources: [MemorySource],
        events: [TimelineEvent]
    ) -> String {
        """
        请基于下列项目、来源和时间线事件生成中文每日简报。

        输出要求：
        - 只使用列出的证据，不要编造事实；如果证据不足，请明确说明。
        - 必须包含最近变化。
        - 必须指出被遗忘的 TODO 或开放问题。
        - 必须给出 1-3 个下一步行动。
        - 必须逐个覆盖“项目”列表中的每个项目；某个项目证据不足时，单独写“证据不足”。
        - 引用证据时使用来源标题和路径，格式如：来源：《标题》 路径：/path/file.md。

        项目：
        \(formatProjects(projects))

        来源片段（已在本地按项目配额和最近修改筛选并截断，不代表完整文件）：
        \(formatSources(SourceSnippetSelector.selectForBrief(projects: projects, sources: sources)))

        时间线事件：
        \(formatEvents(events))
        """
    }

    private func formatProjects(_ projects: [Project]) -> String {
        guard !projects.isEmpty else {
            return "- 无项目记录"
        }

        return projects.map { project in
            "- \(project.name)（路径：\(project.rootPath)）"
        }.joined(separator: "\n")
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

    private func formatEvents(_ events: [TimelineEvent]) -> String {
        guard !events.isEmpty else {
            return "- 无时间线事件"
        }

        return events.map { event in
            """
            - \(event.title)
              摘要：\(event.summary)
            """
        }.joined(separator: "\n")
    }
}
