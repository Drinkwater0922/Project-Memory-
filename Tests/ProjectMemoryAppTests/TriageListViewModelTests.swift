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

    private func writeFramesBackedSession(
        _ store: MemoryStore,
        status: AssignmentStatus,
        category: ActivityCategory,
        endedOffset: TimeInterval,
        projectID: UUID? = nil,
        source: String? = nil
    ) throws -> UUID {
        let now = Date()
        let firstFrame = ActivityFrame(
            observedAt: now.addingTimeInterval(endedOffset - 60),
            bundleID: "com.x",
            appName: "X",
            windowTitle: "t",
            category: category
        )
        let secondFrame = ActivityFrame(
            observedAt: now.addingTimeInterval(endedOffset),
            bundleID: "com.x",
            appName: "X",
            windowTitle: "t",
            category: category
        )
        try store.saveActivityFrame(firstFrame)
        try store.saveActivityFrame(secondFrame)

        let draft = ActivitySessionDraft(
            id: firstFrame.id,
            startedAt: firstFrame.observedAt,
            endedAt: secondFrame.observedAt,
            bundleID: "com.x",
            appName: "X",
            browserHost: nil,
            category: category,
            titleSamples: ["t"],
            frameCount: 2,
            frameIDs: [firstFrame.id, secondFrame.id]
        )
        try store.writeActivitySession(
            ResolvedActivitySession(
                draft: draft,
                assignmentStatus: status,
                projectID: projectID,
                assignmentSource: source
            )
        )
        return firstFrame.id
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

    func testAssignActionSetsManualStatusAndRunsPipeline() async throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/p")
        try store.saveProject(project)
        let id = try writeFramesBackedSession(store, status: .unassigned, category: .work, endedOffset: -60)

        let viewModel = TriageListViewModel(store: store, pipeline: SessionPipeline(store: store))
        viewModel.refresh()
        try await viewModel.assign(sessionID: id, projectID: project.id)

        let sessions = try store.fetchActivitySessions(
            since: Date(timeIntervalSince1970: 0),
            until: Date(timeIntervalSinceNow: 3600)
        )
        let session = sessions.first { $0.id == id }
        XCTAssertEqual(session?.assignmentStatus, .manualAssigned)
        XCTAssertEqual(session?.projectID, project.id)
        XCTAssertEqual(session?.assignmentSource, "manual")
    }

    func testIgnoreActionAndUndoIgnore() async throws {
        let store = try MemoryStore.inMemory()
        let id = try writeFramesBackedSession(store, status: .unassigned, category: .work, endedOffset: -60)
        let viewModel = TriageListViewModel(store: store, pipeline: SessionPipeline(store: store))
        viewModel.refresh()

        try await viewModel.ignore(sessionID: id)
        var session = try store.fetchActivitySessions(
            since: Date(timeIntervalSince1970: 0),
            until: Date(timeIntervalSinceNow: 3600)
        ).first { $0.id == id }
        XCTAssertEqual(session?.assignmentStatus, .ignored)
        XCTAssertEqual(session?.assignmentSource, "manual")

        try await viewModel.undoIgnore(sessionID: id)
        session = try store.fetchActivitySessions(
            since: Date(timeIntervalSince1970: 0),
            until: Date(timeIntervalSinceNow: 3600)
        ).first { $0.id == id }
        XCTAssertEqual(session?.assignmentStatus, .unassigned)
        XCTAssertNil(session?.assignmentSource)
    }
}
