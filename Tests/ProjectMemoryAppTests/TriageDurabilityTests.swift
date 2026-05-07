import XCTest
@testable import ProjectMemoryApp
@testable import ProjectMemoryCore

@MainActor
final class TriageDurabilityTests: XCTestCase {
    private func makeFrames(count: Int, bundleID: String = "com.x", host: String? = nil) -> [ActivityFrame] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map { index in
            ActivityFrame(
                observedAt: base.addingTimeInterval(TimeInterval(index * 60)),
                bundleID: bundleID,
                appName: bundleID,
                windowTitle: "t",
                browserURL: host.map { "https://\($0)/" },
                category: .work
            )
        }
    }

    private func saveFrames(_ frames: [ActivityFrame], in store: MemoryStore) throws {
        for frame in frames {
            try store.saveActivityFrame(frame)
        }
    }

    private func window(for frames: [ActivityFrame]) -> DateInterval {
        DateInterval(
            start: frames.first!.observedAt.addingTimeInterval(-60),
            end: frames.last!.observedAt.addingTimeInterval(60)
        )
    }

    func testManualAssignSurvivesRestart() async throws {
        let path = NSTemporaryDirectory() + "phase2-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let frames = makeFrames(count: 3)
        let project = Project(name: "p", rootPath: "/p")
        let testWindow = window(for: frames)

        do {
            let store = try MemoryStore(path: path)
            try store.saveProject(project)
            try saveFrames(frames, in: store)
            try SessionPipeline(store: store).run(window: testWindow)
            let sessions = try store.fetchActivitySessions(since: testWindow.start, until: testWindow.end)
            XCTAssertEqual(sessions.count, 1)
            try store.updateActivitySessionAssignment(
                sessionID: sessions[0].id,
                assignmentStatus: .manualAssigned,
                projectID: project.id,
                assignmentSource: "manual"
            )
        }

        let reopenedStore = try MemoryStore(path: path)
        let sessions = try reopenedStore.fetchActivitySessions(since: testWindow.start, until: testWindow.end)
        XCTAssertEqual(sessions[0].assignmentStatus, .manualAssigned)
        XCTAssertEqual(sessions[0].projectID, project.id)
    }

    func testManualAssignSurvivesRuleChange() async throws {
        let store = try MemoryStore.inMemory()
        let manualProject = Project(name: "manual", rootPath: "/m")
        let ruleProject = Project(name: "rule", rootPath: "/r")
        try store.saveProject(manualProject)
        try store.saveProject(ruleProject)
        let frames = makeFrames(count: 3)
        try saveFrames(frames, in: store)

        let pipeline = SessionPipeline(store: store)
        let testWindow = window(for: frames)
        try pipeline.run(window: testWindow)
        let sessions = try store.fetchActivitySessions(since: testWindow.start, until: testWindow.end)
        try store.updateActivitySessionAssignment(
            sessionID: sessions[0].id,
            assignmentStatus: .manualAssigned,
            projectID: manualProject.id,
            assignmentSource: "manual"
        )

        try store.upsertRule(
            ProjectActivityRule(
                projectID: ruleProject.id,
                kind: .bundleIDEquals,
                pattern: "com.x",
                isEnabled: true
            )
        )
        try pipeline.run(window: testWindow)

        let after = try store.fetchActivitySessions(since: testWindow.start, until: testWindow.end)
        XCTAssertEqual(after[0].projectID, manualProject.id)
        XCTAssertEqual(after[0].assignmentSource, "manual")
    }

    func testManualAssignSurvivesEndedAtExtension() async throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/p")
        try store.saveProject(project)
        let initialFrames = makeFrames(count: 3)
        try saveFrames(initialFrames, in: store)

        let pipeline = SessionPipeline(store: store)
        let firstWindow = window(for: initialFrames)
        try pipeline.run(window: firstWindow)
        let session = try store.fetchActivitySessions(since: firstWindow.start, until: firstWindow.end)[0]
        try store.updateActivitySessionAssignment(
            sessionID: session.id,
            assignmentStatus: .manualAssigned,
            projectID: project.id,
            assignmentSource: "manual"
        )

        let extraFrames = (0..<2).map { index in
            ActivityFrame(
                observedAt: initialFrames.last!.observedAt.addingTimeInterval(TimeInterval((index + 1) * 60)),
                bundleID: "com.x",
                appName: "com.x",
                windowTitle: "t",
                category: .work
            )
        }
        try saveFrames(extraFrames, in: store)
        let secondWindow = DateInterval(
            start: firstWindow.start,
            end: extraFrames.last!.observedAt.addingTimeInterval(60)
        )
        try pipeline.run(window: secondWindow)

        let after = try store.fetchActivitySessions(since: secondWindow.start, until: secondWindow.end)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].id, session.id)
        XCTAssertEqual(after[0].assignmentStatus, .manualAssigned)
        XCTAssertEqual(after[0].projectID, project.id)
        XCTAssertGreaterThan(after[0].endedAt, session.endedAt)
    }

    func testIgnoredSurvivesRuleMatch() async throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/p")
        try store.saveProject(project)
        let frames = makeFrames(count: 3)
        try saveFrames(frames, in: store)
        try store.upsertRule(ProjectActivityRule(projectID: project.id, kind: .bundleIDEquals, pattern: "com.x", isEnabled: true))

        let pipeline = SessionPipeline(store: store)
        let testWindow = window(for: frames)
        try pipeline.run(window: testWindow)
        let session = try store.fetchActivitySessions(since: testWindow.start, until: testWindow.end)[0]
        try store.updateActivitySessionAssignment(
            sessionID: session.id,
            assignmentStatus: .ignored,
            projectID: nil,
            assignmentSource: "manual"
        )
        try pipeline.run(window: testWindow)

        let after = try store.fetchActivitySessions(since: testWindow.start, until: testWindow.end)
        XCTAssertEqual(after[0].assignmentStatus, .ignored)
        XCTAssertNil(after[0].projectID)
    }

    func testUndoIgnoreReevaluatesRules() async throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/p")
        try store.saveProject(project)
        let frames = makeFrames(count: 3)
        try saveFrames(frames, in: store)
        try store.upsertRule(ProjectActivityRule(projectID: project.id, kind: .bundleIDEquals, pattern: "com.x", isEnabled: true))

        let pipeline = SessionPipeline(store: store)
        let testWindow = window(for: frames)
        try pipeline.run(window: testWindow)
        var session = try store.fetchActivitySessions(since: testWindow.start, until: testWindow.end)[0]
        try store.updateActivitySessionAssignment(
            sessionID: session.id,
            assignmentStatus: .ignored,
            projectID: nil,
            assignmentSource: "manual"
        )
        try pipeline.run(window: testWindow)

        try store.updateActivitySessionAssignment(
            sessionID: session.id,
            assignmentStatus: .unassigned,
            projectID: nil,
            assignmentSource: nil
        )
        try pipeline.run(window: testWindow)

        session = try store.fetchActivitySessions(since: testWindow.start, until: testWindow.end)[0]
        XCTAssertEqual(session.assignmentStatus, .ruleAssigned)
        XCTAssertEqual(session.projectID, project.id)
    }

    func testIgnoreThenAssignOverwrites() async throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/p")
        try store.saveProject(project)
        let frames = makeFrames(count: 3)
        try saveFrames(frames, in: store)

        let pipeline = SessionPipeline(store: store)
        let testWindow = window(for: frames)
        try pipeline.run(window: testWindow)
        let session = try store.fetchActivitySessions(since: testWindow.start, until: testWindow.end)[0]

        try store.updateActivitySessionAssignment(
            sessionID: session.id,
            assignmentStatus: .ignored,
            projectID: nil,
            assignmentSource: "manual"
        )
        try store.updateActivitySessionAssignment(
            sessionID: session.id,
            assignmentStatus: .manualAssigned,
            projectID: project.id,
            assignmentSource: "manual"
        )
        try pipeline.run(window: testWindow)

        let after = try store.fetchActivitySessions(since: testWindow.start, until: testWindow.end)[0]
        XCTAssertEqual(after.assignmentStatus, .manualAssigned)
        XCTAssertEqual(after.projectID, project.id)
    }

    func testRuleAssignmentReevaluatedOnRuleChange() async throws {
        let store = try MemoryStore.inMemory()
        let firstProject = Project(name: "p1", rootPath: "/p1")
        let secondProject = Project(name: "p2", rootPath: "/p2")
        try store.saveProject(firstProject)
        try store.saveProject(secondProject)
        let frames = makeFrames(count: 3)
        try saveFrames(frames, in: store)
        let firstRule = ProjectActivityRule(
            projectID: firstProject.id,
            kind: .bundleIDEquals,
            pattern: "com.x",
            isEnabled: true
        )
        try store.upsertRule(firstRule)

        let pipeline = SessionPipeline(store: store)
        let testWindow = window(for: frames)
        try pipeline.run(window: testWindow)
        XCTAssertEqual(
            try store.fetchActivitySessions(since: testWindow.start, until: testWindow.end)[0].projectID,
            firstProject.id
        )

        try store.upsertRule(
            ProjectActivityRule(
                id: firstRule.id,
                projectID: firstProject.id,
                kind: .bundleIDEquals,
                pattern: "com.x",
                isEnabled: false,
                createdAt: firstRule.createdAt
            )
        )
        try store.upsertRule(
            ProjectActivityRule(
                projectID: secondProject.id,
                kind: .bundleIDEquals,
                pattern: "com.x",
                isEnabled: true
            )
        )
        try pipeline.run(window: testWindow)

        XCTAssertEqual(
            try store.fetchActivitySessions(since: testWindow.start, until: testWindow.end)[0].projectID,
            secondProject.id
        )
    }
}
