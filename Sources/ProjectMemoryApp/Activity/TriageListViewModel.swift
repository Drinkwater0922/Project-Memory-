import Combine
import Foundation
import ProjectMemoryCore

@MainActor
internal final class TriageListViewModel: ObservableObject {
    @Published private(set) var unassignedSessions: [PersistedActivitySession] = []
    @Published private(set) var ignoredSessions: [PersistedActivitySession] = []

    private let store: MemoryStore
    private let lookback: TimeInterval = 7 * 24 * 60 * 60

    init(store: MemoryStore) {
        self.store = store
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
}
