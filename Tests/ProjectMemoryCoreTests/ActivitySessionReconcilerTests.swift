import XCTest
@testable import ProjectMemoryCore

final class ActivitySessionReconcilerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func draft(
        id: UUID = UUID(),
        startedAtOffset: TimeInterval = 0,
        endedAtOffset: TimeInterval = 60,
        category: ActivityCategory = .work,
        browserHost: String? = nil,
        appName: String = "X",
        bundleID: String = "com.x",
        titleSamples: [String] = ["sample"]
    ) -> ActivitySessionDraft {
        let frameIDs = [UUID(), UUID()]
        return ActivitySessionDraft(
            id: id,
            startedAt: now.addingTimeInterval(startedAtOffset),
            endedAt: now.addingTimeInterval(endedAtOffset),
            bundleID: bundleID,
            appName: appName,
            browserHost: browserHost,
            category: category,
            titleSamples: titleSamples,
            frameCount: frameIDs.count,
            frameIDs: frameIDs
        )
    }

    func testReplaceWindowReadsStaleIDsBeforeDeleteAndRemovesStaleSourceByPath() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)
        let oldDraft = draft()
        let oldResolved = ResolvedActivitySession(
            draft: oldDraft,
            assignmentStatus: .manualAssigned,
            projectID: project.id,
            assignmentSource: "manual"
        )
        try store.writeActivitySession(oldResolved)
        let oldSourcePath = "activity-sessions/\(oldDraft.id.uuidString)"
        try store.saveSource(
            MemorySource(
                projectID: project.id,
                kind: .activitySession,
                title: "old",
                path: oldSourcePath,
                extractedText: "old",
                modifiedAt: oldDraft.endedAt
            )
        )

        try ActivitySessionReconciler.replaceWindow(
            since: now.addingTimeInterval(-60),
            until: now.addingTimeInterval(120),
            with: [],
            in: store
        )

        XCTAssertNil(try store.findSourceByPath(oldSourcePath))
        XCTAssertEqual(
            try store.fetchActivitySessions(
                since: now.addingTimeInterval(-60),
                until: now.addingTimeInterval(120)
            ).count,
            0
        )
    }

    func testReplaceWindowOrphanCleanupViaFetchActivitySessionSources() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)
        let orphanPath = "activity-sessions/\(UUID().uuidString)"
        try store.saveSource(
            MemorySource(
                projectID: project.id,
                kind: .activitySession,
                title: "orphan",
                path: orphanPath,
                extractedText: "x",
                modifiedAt: now
            )
        )

        try ActivitySessionReconciler.replaceWindow(
            since: now.addingTimeInterval(-60),
            until: now.addingTimeInterval(120),
            with: [],
            in: store
        )

        XCTAssertNil(try store.findSourceByPath(orphanPath))
    }

    func testMaterializationGateRequiresAssignedWorkAndProjectID() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)

        let d1 = draft()
        let r1 = ResolvedActivitySession(draft: d1, assignmentStatus: .unassigned, projectID: nil, assignmentSource: nil)
        let d2 = draft(category: .socialMedia)
        let r2 = ResolvedActivitySession(draft: d2, assignmentStatus: .manualAssigned, projectID: project.id, assignmentSource: "manual")
        let d3 = draft()
        let r3 = ResolvedActivitySession(draft: d3, assignmentStatus: .manualAssigned, projectID: nil, assignmentSource: "manual")
        let d4 = draft()
        let r4 = ResolvedActivitySession(draft: d4, assignmentStatus: .manualAssigned, projectID: project.id, assignmentSource: "manual")
        let d5 = draft()
        let r5 = ResolvedActivitySession(draft: d5, assignmentStatus: .ruleAssigned, projectID: project.id, assignmentSource: "rule:\(UUID().uuidString)")

        try ActivitySessionReconciler.replaceWindow(
            since: now.addingTimeInterval(-60),
            until: now.addingTimeInterval(120),
            with: [r1, r2, r3, r4, r5],
            in: store
        )

        XCTAssertNil(try store.findSourceByPath("activity-sessions/\(d1.id.uuidString)"))
        XCTAssertNil(try store.findSourceByPath("activity-sessions/\(d2.id.uuidString)"))
        XCTAssertNil(try store.findSourceByPath("activity-sessions/\(d3.id.uuidString)"))
        XCTAssertNotNil(try store.findSourceByPath("activity-sessions/\(d4.id.uuidString)"))
        XCTAssertNotNil(try store.findSourceByPath("activity-sessions/\(d5.id.uuidString)"))
    }

    func testMaterializedBrowserSourceContainsHostButNoTitleSamplesOrURL() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)
        let browserDraft = draft(
            endedAtOffset: 600,
            browserHost: "github.com",
            appName: "Chrome",
            bundleID: "com.google.Chrome",
            titleSamples: ["GitHub", "Pull Request"]
        )
        let resolved = ResolvedActivitySession(
            draft: browserDraft,
            assignmentStatus: .manualAssigned,
            projectID: project.id,
            assignmentSource: "manual"
        )

        try ActivitySessionReconciler.replaceWindow(
            since: now.addingTimeInterval(-60),
            until: now.addingTimeInterval(700),
            with: [resolved],
            in: store
        )

        let materialized = try XCTUnwrap(store.findSourceByPath("activity-sessions/\(browserDraft.id.uuidString)"))
        XCTAssertTrue(materialized.extractedText.contains("github.com"))
        XCTAssertFalse(materialized.extractedText.contains("GitHub"))
        XCTAssertFalse(materialized.extractedText.contains("Pull Request"))
        XCTAssertNil(materialized.url)
        XCTAssertEqual(materialized.projectID, project.id)
        XCTAssertEqual(materialized.kind, .activitySession)
    }

    func testMaterializedNonBrowserWorkSourceContainsTitleSamples() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.saveProject(project)
        let nonBrowserDraft = draft(
            endedAtOffset: 600,
            appName: "Cursor",
            bundleID: "com.todesktop.230313mzl4w4u92",
            titleSamples: ["project-memory · ActivityCoordinator.swift", "Cursor"]
        )
        let resolved = ResolvedActivitySession(
            draft: nonBrowserDraft,
            assignmentStatus: .manualAssigned,
            projectID: project.id,
            assignmentSource: "manual"
        )

        try ActivitySessionReconciler.replaceWindow(
            since: now.addingTimeInterval(-60),
            until: now.addingTimeInterval(700),
            with: [resolved],
            in: store
        )

        let materialized = try XCTUnwrap(store.findSourceByPath("activity-sessions/\(nonBrowserDraft.id.uuidString)"))
        XCTAssertTrue(materialized.extractedText.contains("ActivityCoordinator.swift"))
    }
}
