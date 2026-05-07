import XCTest
@testable import ProjectMemoryApp
@testable import ProjectMemoryCore

@MainActor
final class TriageBadgeCounterTests: XCTestCase {
    func testCountOnlyIncludesUnassignedWorkSessionsInWindow() throws {
        let store = try MemoryStore.inMemory()
        let now = Date()

        try writeSession(store, status: .unassigned, category: .work, endedAt: now.addingTimeInterval(-60))
        try writeSession(store, status: .unassigned, category: .work, endedAt: now.addingTimeInterval(-120))
        try writeSession(store, status: .ignored, category: .work, endedAt: now.addingTimeInterval(-60), source: "manual")
        try writeSession(store, status: .unassigned, category: .chat, endedAt: now.addingTimeInterval(-60))
        try writeSession(store, status: .unassigned, category: .work, endedAt: now.addingTimeInterval(-8 * 24 * 3600))

        let count = try TriageBadgeCounter.count(
            store: store,
            since: now.addingTimeInterval(-7 * 24 * 3600),
            until: now
        )

        XCTAssertEqual(count, 2)
    }

    private func writeSession(
        _ store: MemoryStore,
        status: AssignmentStatus,
        category: ActivityCategory,
        endedAt: Date,
        source: String? = nil
    ) throws {
        let draft = ActivitySessionDraft(
            id: UUID(),
            startedAt: endedAt.addingTimeInterval(-60),
            endedAt: endedAt,
            bundleID: "com.x",
            appName: "X",
            browserHost: nil,
            category: category,
            titleSamples: ["t"],
            frameCount: 2,
            frameIDs: [UUID(), UUID()]
        )
        try store.writeActivitySession(
            ResolvedActivitySession(
                draft: draft,
                assignmentStatus: status,
                projectID: nil,
                assignmentSource: source
            )
        )
    }
}
