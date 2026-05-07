import Foundation

public enum SessionAggregator {
    /// Maximum gap between two consecutive frames within one session.
    /// Spec §6.1 / known limitation: changing this is a breaking config change.
    public static let sessionGapThreshold: TimeInterval = 300  // 5 min

    public static func aggregate(_ frames: [ActivityFrame]) -> [ActivitySessionDraft] {
        let sorted = frames.sorted { $0.observedAt < $1.observedAt }
        guard !sorted.isEmpty else { return [] }

        var drafts: [ActivitySessionDraft] = []
        var current: [ActivityFrame] = []

        for frame in sorted {
            if let last = current.last,
               sameIdentity(last, frame),
               frame.observedAt.timeIntervalSince(last.observedAt) <= sessionGapThreshold {
                current.append(frame)
            } else {
                if let draft = makeDraft(from: current) { drafts.append(draft) }
                current = [frame]
            }
        }
        if let draft = makeDraft(from: current) { drafts.append(draft) }

        return drafts
    }

    private static func sameIdentity(_ a: ActivityFrame, _ b: ActivityFrame) -> Bool {
        guard a.bundleID == b.bundleID else { return false }
        return host(of: a) == host(of: b)
    }

    private static func host(of frame: ActivityFrame) -> String? {
        guard let urlString = frame.browserURL,
              let host = URLComponents(string: urlString)?.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        return host
    }

    private static func makeDraft(from frames: [ActivityFrame]) -> ActivitySessionDraft? {
        guard frames.count >= 2 else { return nil }   // frameCount gate: drop single-frame
        let first = frames[0]
        let last = frames[frames.count - 1]
        let titleSamples = collectTitleSamples(from: frames)
        return ActivitySessionDraft(
            id: first.id,
            startedAt: first.observedAt,
            endedAt: last.observedAt,
            bundleID: first.bundleID,
            appName: first.appName,
            browserHost: host(of: first),
            category: first.category,
            titleSamples: titleSamples,
            frameCount: frames.count,
            frameIDs: frames.map(\.id)
        )
    }

    private static func collectTitleSamples(from frames: [ActivityFrame]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for frame in frames {
            guard let raw = frame.windowTitle else { continue }
            let sanitized = TextSanitizer.stripInvisibleControls(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitized.isEmpty else { continue }
            guard !seen.contains(sanitized) else { continue }
            seen.insert(sanitized)
            result.append(sanitized)
            if result.count >= 5 { break }
        }
        return result
    }
}
