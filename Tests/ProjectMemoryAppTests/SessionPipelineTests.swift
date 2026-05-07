import XCTest
@testable import ProjectMemoryApp
@testable import ProjectMemoryCore

@MainActor
final class SessionPipelineTests: XCTestCase {
    func testPipelinePreservesManualOverRule() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/p")
        try store.saveProject(project)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let firstFrame = ActivityFrame(
            observedAt: now,
            bundleID: "com.x",
            appName: "X",
            windowTitle: "t",
            category: .work
        )
        let secondFrame = ActivityFrame(
            observedAt: now.addingTimeInterval(60),
            bundleID: "com.x",
            appName: "X",
            windowTitle: "t",
            category: .work
        )
        try store.saveActivityFrame(firstFrame)
        try store.saveActivityFrame(secondFrame)

        let draft = ActivitySessionDraft(
            id: firstFrame.id,
            startedAt: now,
            endedAt: now.addingTimeInterval(60),
            bundleID: "com.x",
            appName: "X",
            browserHost: nil,
            category: .work,
            titleSamples: ["t"],
            frameCount: 2,
            frameIDs: [firstFrame.id, secondFrame.id]
        )
        try store.writeActivitySession(
            ResolvedActivitySession(
                draft: draft,
                assignmentStatus: .manualAssigned,
                projectID: project.id,
                assignmentSource: "manual"
            )
        )
        try store.upsertRule(
            ProjectActivityRule(
                projectID: UUID(),
                kind: .bundleIDEquals,
                pattern: "com.x",
                isEnabled: true
            )
        )

        let pipeline = SessionPipeline(store: store)
        let window = DateInterval(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(120))
        try pipeline.run(window: window)

        let sessions = try store.fetchActivitySessions(since: window.start, until: window.end)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].assignmentStatus, .manualAssigned)
        XCTAssertEqual(sessions[0].projectID, project.id)
        XCTAssertEqual(sessions[0].assignmentSource, "manual")
    }

    func testPipelineUndoIgnoreReevaluatesRules() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/p")
        try store.saveProject(project)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let firstFrame = ActivityFrame(
            observedAt: now,
            bundleID: "com.x",
            appName: "X",
            windowTitle: "t",
            category: .work
        )
        let secondFrame = ActivityFrame(
            observedAt: now.addingTimeInterval(60),
            bundleID: "com.x",
            appName: "X",
            windowTitle: "t",
            category: .work
        )
        try store.saveActivityFrame(firstFrame)
        try store.saveActivityFrame(secondFrame)
        let rule = ProjectActivityRule(
            projectID: project.id,
            kind: .bundleIDEquals,
            pattern: "com.x",
            isEnabled: true
        )
        try store.upsertRule(rule)

        let pipeline = SessionPipeline(store: store)
        let window = DateInterval(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(120))
        try pipeline.run(window: window)

        var sessions = try store.fetchActivitySessions(since: window.start, until: window.end)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].assignmentStatus, .ruleAssigned)

        try store.updateActivitySessionAssignment(
            sessionID: sessions[0].id,
            assignmentStatus: .unassigned,
            projectID: nil,
            assignmentSource: nil
        )
        try pipeline.run(window: window)

        sessions = try store.fetchActivitySessions(since: window.start, until: window.end)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].assignmentStatus, .ruleAssigned)
        XCTAssertEqual(sessions[0].projectID, project.id)
        XCTAssertEqual(sessions[0].assignmentSource, "rule:\(rule.id.uuidString)")
    }
}
