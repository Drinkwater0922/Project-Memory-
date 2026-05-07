import Foundation
import ProjectMemoryCore

@MainActor
final class SessionPipeline {
    private let store: MemoryStore

    init(store: MemoryStore) {
        self.store = store
    }

    func run(window: DateInterval) throws {
        let preserved = try store.fetchActivitySessionAssignments(since: window.start, until: window.end)
        let preservedByID = Dictionary(uniqueKeysWithValues: preserved.map { ($0.sessionID, $0) })

        let frames = try store.fetchActivityFrames(since: window.start, until: window.end)
        let framesByID = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0) })

        let drafts = SessionAggregator.aggregate(frames)
        let rules = try store.fetchRules()
        let resolved = drafts.map { draft in
            AssignmentResolver.resolve(
                draft: draft,
                rules: rules,
                preserved: preservedByID[draft.id],
                relatedFrames: draft.frameIDs.compactMap { framesByID[$0] }
            )
        }

        try ActivitySessionReconciler.replaceWindow(
            since: window.start,
            until: window.end,
            with: resolved,
            in: store
        )
    }
}
