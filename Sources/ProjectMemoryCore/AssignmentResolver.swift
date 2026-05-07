import Foundation

public enum AssignmentResolver {
    public static func resolve(
        draft: ActivitySessionDraft,
        rules: [ProjectActivityRule],
        preserved: PreservedAssignment?,
        relatedFrames: [ActivityFrame]
    ) -> ResolvedActivitySession {
        if let preserved {
            return ResolvedActivitySession(
                draft: draft,
                assignmentStatus: preserved.assignmentStatus,
                projectID: preserved.projectID,
                assignmentSource: "manual"
            )
        }

        let enabled = rules.filter { $0.isEnabled }
        let kindOrder: [ProjectActivityRule.Kind] = [.urlContains, .titleContains, .bundleIDEquals]

        for kind in kindOrder {
            let bucket = enabled
                .filter { $0.kind == kind }
                .sorted { $0.createdAt < $1.createdAt }
            for rule in bucket {
                if matches(rule: rule, draft: draft, relatedFrames: relatedFrames) {
                    return ResolvedActivitySession(
                        draft: draft,
                        assignmentStatus: .ruleAssigned,
                        projectID: rule.projectID,
                        assignmentSource: "rule:\(rule.id.uuidString)"
                    )
                }
            }
        }

        return ResolvedActivitySession(draft: draft, assignmentStatus: .unassigned, projectID: nil, assignmentSource: nil)
    }

    private static func matches(rule: ProjectActivityRule, draft: ActivitySessionDraft, relatedFrames: [ActivityFrame]) -> Bool {
        let pattern = rule.pattern
        switch rule.kind {
        case .urlContains:
            let needle = pattern.lowercased()
            for frame in relatedFrames {
                guard let url = frame.browserURL,
                      let normalized = normalizeURLForMatch(url) else { continue }
                if normalized.contains(needle) { return true }
            }
            return false
        case .titleContains:
            let needle = pattern.lowercased()
            for frame in relatedFrames {
                guard let title = frame.windowTitle else { continue }
                let normalized = TextSanitizer.stripInvisibleControls(title).lowercased()
                if normalized.contains(needle) { return true }
            }
            return false
        case .bundleIDEquals:
            return draft.bundleID == pattern
        }
    }

    /// Lowercase host + drop query/fragment; preserve scheme + path for `contains` matching.
    private static func normalizeURLForMatch(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.host != nil
        else { return nil }
        components.host = components.host?.lowercased()
        components.fragment = nil
        components.queryItems = nil
        return components.string?.lowercased()
    }
}
