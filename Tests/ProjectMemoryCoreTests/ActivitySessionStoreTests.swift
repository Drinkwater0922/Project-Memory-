import XCTest
@testable import ProjectMemoryCore

final class ActivitySessionStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeResolved(
        id: UUID = UUID(),
        startedAtOffset: TimeInterval = 0,
        endedAtOffset: TimeInterval = 60,
        status: AssignmentStatus = .unassigned,
        projectID: UUID? = nil,
        source: String? = nil,
        category: ActivityCategory = .work,
        frameIDs: [UUID] = [UUID(), UUID()],
        titleSamples: [String] = ["a"]
    ) -> ResolvedActivitySession {
        let draft = ActivitySessionDraft(
            id: id,
            startedAt: now.addingTimeInterval(startedAtOffset),
            endedAt: now.addingTimeInterval(endedAtOffset),
            bundleID: "com.x",
            appName: "X",
            browserHost: nil,
            category: category,
            titleSamples: titleSamples,
            frameCount: frameIDs.count,
            frameIDs: frameIDs
        )
        return ResolvedActivitySession(
            draft: draft,
            assignmentStatus: status,
            projectID: projectID,
            assignmentSource: source
        )
    }

    func testWriteAndFetchActivitySession() throws {
        let store = try MemoryStore.inMemory()
        let projectID = UUID()
        let ruleID = UUID()
        let resolved = makeResolved(
            status: .ruleAssigned,
            projectID: projectID,
            source: "rule:\(ruleID.uuidString)",
            titleSamples: ["a", "b"]
        )

        try store.writeActivitySession(resolved)

        let rows = try store.fetchActivitySessions(
            since: now.addingTimeInterval(-60),
            until: now.addingTimeInterval(120)
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, resolved.draft.id)
        XCTAssertEqual(rows[0].startedAt, resolved.draft.startedAt)
        XCTAssertEqual(rows[0].endedAt, resolved.draft.endedAt)
        XCTAssertEqual(rows[0].assignmentStatus, .ruleAssigned)
        XCTAssertEqual(rows[0].projectID, projectID)
        XCTAssertEqual(rows[0].assignmentSource, "rule:\(ruleID.uuidString)")
        XCTAssertEqual(rows[0].titleSamples, ["a", "b"])
        XCTAssertEqual(rows[0].frameCount, 2)
    }

    func testFetchActivitySessionIDsUsesWindowOverlap() throws {
        let store = try MemoryStore.inMemory()
        let overlappingFromBefore = makeResolved(startedAtOffset: -120, endedAtOffset: 30)
        let inside = makeResolved(startedAtOffset: 10, endedAtOffset: 60)
        let afterWindow = makeResolved(startedAtOffset: 300, endedAtOffset: 360)
        let beforeWindow = makeResolved(startedAtOffset: -600, endedAtOffset: -300)
        try store.writeActivitySession(overlappingFromBefore)
        try store.writeActivitySession(inside)
        try store.writeActivitySession(afterWindow)
        try store.writeActivitySession(beforeWindow)

        let ids = try store.fetchActivitySessionIDs(
            since: now,
            until: now.addingTimeInterval(120)
        )

        XCTAssertEqual(Set(ids), [overlappingFromBefore.draft.id, inside.draft.id])
    }

    func testDeleteActivitySessionsAlsoClearsJoinTable() throws {
        let store = try MemoryStore.inMemory()
        let resolved = makeResolved(frameIDs: [UUID(), UUID(), UUID()])
        try store.writeActivitySession(resolved)

        try store.deleteActivitySessions(ids: [resolved.draft.id])

        let remaining = try store.fetchActivitySessions(
            since: now.addingTimeInterval(-60),
            until: now.addingTimeInterval(120)
        )
        XCTAssertEqual(remaining.count, 0)
        XCTAssertEqual(try store.executeRawCountForTest("SELECT COUNT(*) AS n FROM activity_session_frames"), 0)
    }

    func testWriteActivitySessionReplacesJoinRowsForSameSession() throws {
        let store = try MemoryStore.inMemory()
        let sessionID = UUID()
        try store.writeActivitySession(makeResolved(id: sessionID, frameIDs: [UUID(), UUID()]))
        try store.writeActivitySession(makeResolved(id: sessionID, frameIDs: [UUID()]))

        XCTAssertEqual(try store.executeRawCountForTest("SELECT COUNT(*) AS n FROM activity_session_frames"), 1)
    }

    func testUpdateActivitySessionAssignment() throws {
        let store = try MemoryStore.inMemory()
        let resolved = makeResolved()
        try store.writeActivitySession(resolved)
        let projectID = UUID()

        try store.updateActivitySessionAssignment(
            sessionID: resolved.draft.id,
            assignmentStatus: .manualAssigned,
            projectID: projectID,
            assignmentSource: "manual"
        )

        let updated = try store.fetchActivitySessions(
            since: now.addingTimeInterval(-60),
            until: now.addingTimeInterval(120)
        )
        XCTAssertEqual(updated[0].assignmentStatus, .manualAssigned)
        XCTAssertEqual(updated[0].projectID, projectID)
        XCTAssertEqual(updated[0].assignmentSource, "manual")
    }

    func testFetchActivitySessionAssignmentsOnlyManualAssignedOrIgnored() throws {
        let store = try MemoryStore.inMemory()
        let manual = makeResolved(status: .manualAssigned, projectID: UUID(), source: "manual")
        let ignored = makeResolved(status: .ignored, projectID: nil, source: "manual")
        let rule = makeResolved(status: .ruleAssigned, projectID: UUID(), source: "rule:\(UUID().uuidString)")
        let unassigned = makeResolved(status: .unassigned, projectID: nil, source: nil)
        try store.writeActivitySession(manual)
        try store.writeActivitySession(ignored)
        try store.writeActivitySession(rule)
        try store.writeActivitySession(unassigned)

        let preserved = try store.fetchActivitySessionAssignments(
            since: now.addingTimeInterval(-60),
            until: now.addingTimeInterval(120)
        )

        let ids = Set(preserved.map(\.sessionID))
        XCTAssertTrue(ids.contains(manual.draft.id))
        XCTAssertTrue(ids.contains(ignored.draft.id))
        XCTAssertFalse(ids.contains(rule.draft.id))
        XCTAssertFalse(ids.contains(unassigned.draft.id))
    }

    func testCorruptTitleSamplesJSONThrowsInvalidRow() throws {
        let store = try MemoryStore.inMemory()
        let id = UUID()
        try store.executeRawForTest(
            """
            INSERT INTO activity_sessions
            (id, started_at, ended_at, bundle_id, app_name, browser_host, category,
             assignment_status, project_id, assignment_source, title_samples_json, frame_count)
            VALUES
            ('\(id.uuidString)', '2023-11-14T22:13:20Z', '2023-11-14T22:14:20Z',
             'com.x', 'X', NULL, 'work', 'unassigned', NULL, NULL, 'not json', 2)
            """
        )

        XCTAssertThrowsError(
            try store.fetchActivitySessions(
                since: now.addingTimeInterval(-60),
                until: now.addingTimeInterval(120)
            )
        ) { error in
            XCTAssertEqual(error as? MemoryStoreError, .invalidRow("title_samples_json"))
        }
    }
}
