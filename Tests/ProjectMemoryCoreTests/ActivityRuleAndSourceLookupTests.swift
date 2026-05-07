import XCTest
@testable import ProjectMemoryCore

final class ActivityRuleAndSourceLookupTests: XCTestCase {
    func testRuleUpsertFetchOrdersByCreatedAtAndDelete() throws {
        let store = try MemoryStore.inMemory()
        let projectID = UUID()
        let later = ProjectActivityRule(
            id: UUID(),
            projectID: projectID,
            kind: .urlContains,
            pattern: "  GitHub.com/MyOrg  ",
            isEnabled: true,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let earlier = ProjectActivityRule(
            id: UUID(),
            projectID: projectID,
            kind: .titleContains,
            pattern: "Spec",
            isEnabled: true,
            createdAt: Date(timeIntervalSince1970: 10)
        )

        try store.upsertRule(later)
        try store.upsertRule(earlier)

        var fetched = try store.fetchRules()
        XCTAssertEqual(fetched.map(\.id), [earlier.id, later.id])
        XCTAssertEqual(fetched[1].pattern, "GitHub.com/MyOrg")

        let updated = ProjectActivityRule(
            id: later.id,
            projectID: later.projectID,
            kind: .urlContains,
            pattern: "github.com/other",
            isEnabled: false,
            createdAt: later.createdAt
        )
        try store.upsertRule(updated)
        fetched = try store.fetchRules()
        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(fetched[1], updated)

        try store.deleteRule(id: earlier.id)
        fetched = try store.fetchRules()
        XCTAssertEqual(fetched.map(\.id), [later.id])
    }

    func testFindSourceByPathIgnoresProjectID() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)
        let source = MemorySource(
            projectID: project.id,
            kind: .activitySession,
            title: "Activity",
            path: "activity-sessions/\(UUID().uuidString)",
            extractedText: "x",
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        try store.saveSource(source)

        let found = try store.findSourceByPath(source.path)

        XCTAssertEqual(found?.id, source.id)
        XCTAssertEqual(found?.projectID, project.id)
        XCTAssertNil(try store.findSourceByPath("activity-sessions/missing"))
    }

    func testFetchActivitySessionSourcesFiltersKindAndWindow() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let inWindow = MemorySource(
            projectID: project.id,
            kind: .activitySession,
            title: "in",
            path: "activity-sessions/\(UUID().uuidString)",
            extractedText: "x",
            modifiedAt: now
        )
        let outOfWindow = MemorySource(
            projectID: project.id,
            kind: .activitySession,
            title: "out",
            path: "activity-sessions/\(UUID().uuidString)",
            extractedText: "x",
            modifiedAt: now.addingTimeInterval(-3600 * 24 * 30)
        )
        let nonActivity = MemorySource(
            projectID: project.id,
            kind: .markdown,
            title: "md",
            path: "/tmp/p/notes.md",
            extractedText: "x",
            modifiedAt: now
        )

        try store.saveSource(inWindow)
        try store.saveSource(outOfWindow)
        try store.saveSource(nonActivity)

        let found = try store.fetchActivitySessionSources(
            since: now.addingTimeInterval(-60),
            until: now.addingTimeInterval(60)
        )

        XCTAssertEqual(found.map(\.id), [inWindow.id])
    }

    func testMalformedRuleKindThrowsInvalidRow() throws {
        let store = try MemoryStore.inMemory()
        try store.executeRawForTest(
            """
            INSERT INTO project_activity_rules
            (id, project_id, kind, pattern, is_enabled, created_at)
            VALUES
            ('\(UUID().uuidString)', '\(UUID().uuidString)', 'badKind', 'x', 1, '2023-11-14T22:13:20Z')
            """
        )

        XCTAssertThrowsError(try store.fetchRules()) { error in
            XCTAssertEqual(error as? MemoryStoreError, .invalidRow("kind"))
        }
    }
}
