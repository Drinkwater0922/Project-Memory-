import Combine
import Foundation
import ProjectMemoryCore

@MainActor
internal final class TriageListViewModel: ObservableObject {
    @Published private(set) var unassignedSessions: [PersistedActivitySession] = []
    @Published private(set) var ignoredSessions: [PersistedActivitySession] = []

    private let store: MemoryStore
    private let pipeline: SessionPipeline
    private let lookback: TimeInterval = 7 * 24 * 60 * 60

    init(store: MemoryStore, pipeline: SessionPipeline? = nil) {
        self.store = store
        self.pipeline = pipeline ?? SessionPipeline(store: store)
    }

    var badgeCount: Int {
        unassignedSessions.count
    }

    func refresh() {
        let until = Date()
        let since = until.addingTimeInterval(-lookback)

        do {
            let sessions = try store.fetchActivitySessions(since: since, until: until)
            unassignedSessions = sessions.filter {
                $0.assignmentStatus == .unassigned && $0.category == .work
            }
            ignoredSessions = sessions.filter {
                $0.assignmentStatus == .ignored
            }
        } catch {
            unassignedSessions = []
            ignoredSessions = []
        }
    }

    func assign(sessionID: UUID, projectID: UUID) async throws {
        try await applyAndRerun(
            sessionID: sessionID,
            status: .manualAssigned,
            projectID: projectID,
            source: "manual"
        )
    }

    func ignore(sessionID: UUID) async throws {
        try await applyAndRerun(
            sessionID: sessionID,
            status: .ignored,
            projectID: nil,
            source: "manual"
        )
    }

    func undoIgnore(sessionID: UUID) async throws {
        try await applyAndRerun(
            sessionID: sessionID,
            status: .unassigned,
            projectID: nil,
            source: nil
        )
    }

    private func applyAndRerun(
        sessionID: UUID,
        status: AssignmentStatus,
        projectID: UUID?,
        source: String?
    ) async throws {
        guard let session = try fetchSession(id: sessionID) else {
            return
        }

        try store.updateActivitySessionAssignment(
            sessionID: sessionID,
            assignmentStatus: status,
            projectID: projectID,
            assignmentSource: source
        )

        // Activity frame fetches use an open-right `until` bound; include the
        // last observed frame when rerunning exactly this session's window.
        let window = DateInterval(
            start: session.startedAt,
            end: session.endedAt.addingTimeInterval(1)
        )
        try pipeline.run(window: window)
        refresh()
    }

    private func fetchSession(id: UUID) throws -> PersistedActivitySession? {
        let sessions = try store.fetchActivitySessions(
            since: Date(timeIntervalSince1970: 0),
            until: Date(timeIntervalSinceNow: 3600)
        )
        return sessions.first { $0.id == id }
    }
}
