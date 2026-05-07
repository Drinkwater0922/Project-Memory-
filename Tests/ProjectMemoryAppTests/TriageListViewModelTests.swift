import XCTest
@testable import ProjectMemoryApp
@testable import ProjectMemoryCore

@MainActor
final class TriageListViewModelTests: XCTestCase {
    private func writeSession(
        _ store: MemoryStore,
        status: AssignmentStatus,
        category: ActivityCategory,
        endedOffset: TimeInterval,
        projectID: UUID? = nil,
        source: String? = nil,
        frameIDs: [UUID] = [UUID(), UUID()]
    ) throws -> UUID {
        let now = Date()
        let draft = ActivitySessionDraft(
            id: UUID(),
            startedAt: now.addingTimeInterval(endedOffset - 60),
            endedAt: now.addingTimeInterval(endedOffset),
            bundleID: "com.x",
            appName: "X",
            browserHost: nil,
            category: category,
            titleSamples: ["t"],
            frameCount: 2,
            frameIDs: frameIDs
        )
        let resolved = ResolvedActivitySession(
            draft: draft,
            assignmentStatus: status,
            projectID: projectID,
            assignmentSource: source
        )
        try store.writeActivitySession(resolved)
        return draft.id
    }

    func testDefaultFilterIsUnassignedAndWork() throws {
        let store = try MemoryStore.inMemory()
        let unassignedWorkID = try writeSession(store, status: .unassigned, category: .work, endedOffset: -60)
        _ = try writeSession(store, status: .unassigned, category: .socialMedia, endedOffset: -60)
        _ = try writeSession(
            store,
            status: .ruleAssigned,
            category: .work,
            endedOffset: -60,
            projectID: UUID(),
            source: "rule:\(UUID().uuidString)"
        )

        let viewModel = TriageListViewModel(store: store)
        viewModel.refresh()

        XCTAssertEqual(viewModel.unassignedSessions.count, 1)
        XCTAssertEqual(viewModel.unassignedSessions[0].id, unassignedWorkID)
    }

    func testBadgeCountMatchesUnassignedWorkCount() throws {
        let store = try MemoryStore.inMemory()
        _ = try writeSession(store, status: .unassigned, category: .work, endedOffset: -60)
        _ = try writeSession(store, status: .unassigned, category: .work, endedOffset: -120)
        _ = try writeSession(store, status: .ignored, category: .work, endedOffset: -60, source: "manual")

        let viewModel = TriageListViewModel(store: store)
        viewModel.refresh()

        XCTAssertEqual(viewModel.badgeCount, 2)
    }

    func testIgnoredFolderShowsIgnoredSessions() throws {
        let store = try MemoryStore.inMemory()
        let ignoredID = try writeSession(store, status: .ignored, category: .work, endedOffset: -60, source: "manual")

        let viewModel = TriageListViewModel(store: store)
        viewModel.refresh()

        XCTAssertEqual(viewModel.ignoredSessions.count, 1)
        XCTAssertEqual(viewModel.ignoredSessions[0].id, ignoredID)
    }
}
