import XCTest
@testable import ProjectMemoryCore

final class MemoryStoreTests: XCTestCase {
    func testCreateAndFetchProject() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(
            name: "Alpha",
            rootPath: "/tmp/alpha",
            createdAt: Date(timeIntervalSince1970: 100)
        )

        try store.saveProject(project)
        let projects = try store.fetchProjects()

        XCTAssertEqual(projects, [project])
    }

    func testCreateSourceAndTimelineEvent() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(
            name: "Alpha",
            rootPath: "/tmp/alpha",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        try store.saveProject(project)

        let source = MemorySource(
            projectID: project.id,
            kind: .markdown,
            title: "Plan",
            path: "/tmp/alpha/plan.md",
            extractedText: "Ship the first dogfood build.",
            modifiedAt: Date(timeIntervalSince1970: 101),
            indexedAt: Date(timeIntervalSince1970: 102)
        )
        try store.saveSource(source)

        let event = TimelineEvent(
            projectID: project.id,
            sourceID: source.id,
            kind: .sourceAdded,
            title: "Plan indexed",
            summary: "Plan was indexed.",
            occurredAt: Date(timeIntervalSince1970: 103)
        )
        try store.saveTimelineEvent(event)

        XCTAssertEqual(try store.fetchSources(projectID: project.id), [source])
        XCTAssertEqual(try store.fetchTimeline(projectID: project.id), [event])
    }

    func testFindSourceByProjectAndPath() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "Alpha", rootPath: "/tmp/alpha")
        try store.saveProject(project)
        let source = MemorySource(
            projectID: project.id,
            kind: .markdown,
            title: "Plan",
            path: "/tmp/alpha/plan.md",
            extractedText: "Plan",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        try store.saveSource(source)

        let found = try store.findSource(projectID: project.id, path: source.path)
        XCTAssertEqual(found?.id, source.id)
        XCTAssertEqual(found?.projectID, project.id)
        XCTAssertEqual(found?.path, source.path)
    }

    func testDeleteSourceRemovesSourceAndEvents() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "Alpha", rootPath: "/tmp/alpha")
        try store.saveProject(project)
        let source = MemorySource(
            projectID: project.id,
            kind: .markdown,
            title: "Plan",
            path: "/tmp/alpha/plan.md",
            extractedText: "Plan",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        try store.saveSource(source)
        try store.saveTimelineEvent(
            TimelineEvent(
                projectID: project.id,
                sourceID: source.id,
                kind: .sourceAdded,
                title: "Added",
                summary: "Added",
                occurredAt: Date(timeIntervalSince1970: 2)
            )
        )

        try store.deleteSource(id: source.id)

        XCTAssertEqual(try store.fetchSources(projectID: project.id), [])
        XCTAssertEqual(try store.fetchTimeline(projectID: project.id), [])
    }

    func testDeleteProjectCascadesToSourcesTimelineAndBriefs() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "Alpha", rootPath: "/tmp/alpha")
        try store.saveProject(project)
        let source = MemorySource(
            projectID: project.id,
            kind: .markdown,
            title: "Plan",
            path: "/tmp/alpha/plan.md",
            extractedText: "Plan",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        try store.saveSource(source)
        try store.saveTimelineEvent(
            TimelineEvent(
                projectID: project.id,
                sourceID: source.id,
                kind: .sourceAdded,
                title: "Added",
                summary: "Added",
                occurredAt: Date(timeIntervalSince1970: 2)
            )
        )
        try store.saveBrief(
            Brief(
                projectID: project.id,
                title: "Project Brief",
                body: "Brief",
                sourceIDs: [source.id],
                createdAt: Date(timeIntervalSince1970: 3)
            )
        )

        try store.deleteProject(id: project.id)

        XCTAssertEqual(try store.fetchProjects(), [])
        XCTAssertEqual(try store.fetchSources(projectID: project.id), [])
        XCTAssertEqual(try store.fetchTimeline(projectID: project.id), [])
        XCTAssertNil(try store.fetchLatestBrief(projectID: project.id))
    }

    func testBriefPersistence() throws {
        let store = try MemoryStore.inMemory()
        let sourceID = UUID()
        let brief = Brief(
            projectID: nil,
            title: "Daily Brief",
            body: "Resume the MVP.",
            sourceIDs: [sourceID],
            createdAt: Date(timeIntervalSince1970: 10)
        )

        try store.saveBrief(brief)

        XCTAssertEqual(try store.fetchLatestBrief(), brief)
    }

    func testFetchTimelineLimitAndSince() throws {
        let store = try MemoryStore.inMemory()
        let project = Project(name: "Alpha", rootPath: "/tmp/alpha")
        try store.saveProject(project)
        for index in 0..<5 {
            try store.saveTimelineEvent(
                TimelineEvent(
                    projectID: project.id,
                    sourceID: nil,
                    kind: .sourceUpdated,
                    title: "Event \(index)",
                    summary: "Summary \(index)",
                    occurredAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }

        let events = try store.fetchTimeline(
            projectID: project.id,
            limit: 2,
            since: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(events.map(\.title), ["Event 4", "Event 3"])
    }

    func testMalformedStoredUUIDThrowsInsteadOfCrashing() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try MemoryStore(path: path)
        let database = try SQLiteDatabase(path: path)
        try database.execute(
            """
            INSERT INTO projects (id, name, root_path, created_at)
            VALUES (?, ?, ?, ?)
            """,
            values: [
                .text("not-a-uuid"),
                .text("Broken"),
                .text("/tmp/broken"),
                .text("2026-05-06T00:00:00Z")
            ]
        )

        XCTAssertThrowsError(try store.fetchProjects()) { error in
            XCTAssertEqual(error as? MemoryStoreError, .invalidRow("id"))
        }
    }

    func testMalformedBriefSourceIDsThrows() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try MemoryStore(path: path)
        let database = try SQLiteDatabase(path: path)
        try database.execute(
            """
            INSERT INTO briefs (id, project_id, title, body, source_ids, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            values: [
                .text(UUID().uuidString),
                .null,
                .text("Broken Brief"),
                .text("Body"),
                .text("{not-json"),
                .text("2026-05-06T00:00:00Z")
            ]
        )

        XCTAssertThrowsError(try store.fetchLatestBrief()) { error in
            XCTAssertEqual(error as? MemoryStoreError, .invalidRow("source_ids"))
        }
    }
}
