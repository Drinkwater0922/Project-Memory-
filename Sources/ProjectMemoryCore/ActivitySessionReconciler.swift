import Foundation

public enum ActivitySessionReconciler {
    /// Window replacement order is load-bearing; see Phase 2 spec §6.3.
    public static func replaceWindow(
        since: Date,
        until: Date,
        with resolved: [ResolvedActivitySession],
        in store: MemoryStore
    ) throws {
        let staleIDs = try store.fetchActivitySessionIDs(since: since, until: until)

        try store.deleteActivitySessions(ids: staleIDs)

        for staleID in staleIDs {
            let path = activitySessionPath(staleID)
            if let source = try store.findSourceByPath(path) {
                try store.deleteSource(id: source.id)
            }
        }

        let orphans = try store.fetchActivitySessionSources(since: since, until: until)
        for orphan in orphans {
            try store.deleteSource(id: orphan.id)
        }

        for session in resolved {
            try store.writeActivitySession(session)
        }

        for session in resolved {
            guard shouldMaterialize(session),
                  let projectID = session.projectID,
                  let extractedText = makeExtractedText(session.draft)
            else {
                continue
            }

            try store.saveSource(
                MemorySource(
                    projectID: projectID,
                    kind: .activitySession,
                    title: makeTitle(session.draft),
                    path: activitySessionPath(session.draft.id),
                    url: nil,
                    extractedText: extractedText,
                    modifiedAt: session.draft.endedAt
                )
            )
        }
    }

    static func makeExtractedText(_ draft: ActivitySessionDraft) -> String? {
        guard draft.category == .work else {
            return nil
        }

        var lines: [String] = []
        lines.append("应用：\(draft.appName)")
        lines.append("时长：\(formatDuration(draft.startedAt, draft.endedAt))")
        lines.append("时间：\(formatTimeRange(draft.startedAt, draft.endedAt))")

        if let host = draft.browserHost {
            lines.append("网址：\(host)")
        } else {
            let topTitles = draft.titleSamples.prefix(3).map { String($0.prefix(120)) }
            if !topTitles.isEmpty {
                lines.append("窗口：")
                for title in topTitles {
                    lines.append("  - \(title)")
                }
            }
        }

        return TextSanitizer.stripInvisibleControls(lines.joined(separator: "\n"))
    }

    private static func shouldMaterialize(_ session: ResolvedActivitySession) -> Bool {
        let assigned = session.assignmentStatus == .manualAssigned || session.assignmentStatus == .ruleAssigned
        return assigned && session.draft.category == .work && session.projectID != nil
    }

    private static func activitySessionPath(_ id: UUID) -> String {
        "activity-sessions/\(id.uuidString)"
    }

    private static func makeTitle(_ draft: ActivitySessionDraft) -> String {
        if let host = draft.browserHost {
            return "\(draft.appName) · \(host)"
        }
        return draft.appName
    }

    private static func formatDuration(_ start: Date, _ end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(remainingSeconds)s"
        }
        return "\(remainingSeconds)s"
    }

    private static let timeRangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static func formatTimeRange(_ start: Date, _ end: Date) -> String {
        "\(timeRangeFormatter.string(from: start)) - \(timeRangeFormatter.string(from: end))"
    }
}
